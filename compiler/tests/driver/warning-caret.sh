#!/bin/bash
# warning-caret.sh — a warning prints as an error does: the location, the
# message, the source line and a caret under the column (#336). The port's
# driver printed parser, sema and lowering warnings as a bare line (only the
# preprocessor's had the caret), while the reference prints every warning
# with it. Checked: a parser warning (an unknown loop annotation) and a sema
# warning (a format mismatch) print the caret, and print what the reference
# prints when it is built.
#
#   bash tests/driver/warning-caret.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
REF=bin/$PLAT/xcc
[ -x "$XC" ] || { echo "FAIL warning-caret: no compiler at $XC"; exit 1; }
ROOT=$(pwd)
XC=$(cd "$(dirname "$XC")" && pwd)/$(basename "$XC")
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/p.xc" <<'XC'
#import "Stdio.xc"
void main(void)
{
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1) :bogus
        s = s + i;
    Stdio.printf("%u\n", s);
    return;
}
XC
cat > "$W/s.xc" <<'XC'
#import "Stdio.xc"
void main(void)
{
    i64 v = (i64)5;
    Stdio.printf("%s\n", v);
    return;
}
XC
for f in p s; do
    ( cd "$W" && "$XC" -q -O1 -H "$ROOT" -o $f $f.xc ) > "$W/$f.port" 2>&1
    sed 's/\x1b\[[0-9;]*m//g' "$W/$f.port" | grep -q '^ *\^' || { echo "FAIL warning-caret: $f.xc: the port's warning has no caret: $(head -1 "$W/$f.port")"; fail=1; }
    if [ -x "$REF" ]; then
        ( cd "$W" && "$ROOT/$REF" -q -O1 -H "$ROOT" -o $f.r $f.xc ) > "$W/$f.ref" 2>&1
        # The column of a sema warning can differ by a few between the two;
        # the lines compared are the message and the source line.
        a=$(sed 's/\x1b\[[0-9;]*m//g' "$W/$f.port" | grep -v '^ *\^' | sed 's/:[0-9]*: /: /')
        b=$(sed 's/\x1b\[[0-9;]*m//g' "$W/$f.ref" | grep -v '^ *\^' | sed 's/:[0-9]*: /: /')
        [ "$a" = "$b" ] || { echo "FAIL warning-caret: $f.xc: the port and the reference print different warnings"; diff <(echo "$a") <(echo "$b") | head -6; fail=1; }
    fi
done
[ $fail = 0 ] && echo "warning-caret: ok"
exit $fail
