#!/bin/bash
# log-via-use.sh — Log's format methods called bare under `use Log` get the
# same treatment as Log.error (#336). The bare spelling skipped the format
# fitting, the check and the promotions, which only Stdio.printf's bare
# spelling had: `error("%d", v)` with an i64 of 5000000000 printed 705032704,
# and `error("%s", v)` with a number was not warned about. Checked in both
# compilers, for error, warning and info.
#
#   bash tests/driver/log-via-use.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
REF=bin/$PLAT/xcc
[ -x "$XC" ] || { echo "FAIL log-via-use: no compiler at $XC"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/v.xc" <<'XC'
#import "Stdio.xc"
#import "Log.xc"
use Log;
void main(void)
{
    i64 v = (i64)5000000000;
    u32 w = (u32)4000000000;
    error("e %d %u\n", v, w);
    warning("w %d %u\n", v, w);
    info("i %d %u\n", v, w);
    return;
}
XC
cat > "$W/c.xc" <<'XC'
#import "Log.xc"
use Log;
void main(void)
{
    i64 v = (i64)5;
    error("%s\n", v);
    return;
}
XC
for c in "$XC" "$REF"; do
    [ -x "$c" ] || continue
    "$c" -q -O1 -H . -o "$W/v" "$W/v.xc" > "$W/out" 2>&1 || { echo "FAIL log-via-use: $c does not build"; tail -3 "$W/out"; fail=1; continue; }
    got=$(XC_LOG_LEVEL=info "$W/v" 2>&1 | grep -oE '[ewi] [0-9]+ [0-9]+' | tr '\n' ' ')
    case "$got" in
        *"e 5000000000 4000000000"*) ;;
        *) echo "FAIL log-via-use: $c: bare error printed '$got'"; fail=1 ;;
    esac
    case "$got" in
        *" 705032704 "*) echo "FAIL log-via-use: $c: a bare Log call printed an i64's low 32 bits: '$got'"; fail=1 ;;
    esac
    "$c" -q -O1 -H . -o "$W/c" "$W/c.xc" > "$W/out" 2>&1
    grep -q "error (Log.error via use): '%s' expects a string" "$W/out" \
        || { echo "FAIL log-via-use: $c: no format warning for bare error(\"%s\", i64): $(grep -m1 warning "$W/out")"; fail=1; }
done
[ $fail = 0 ] && echo "log-via-use: ok"
exit $fail
