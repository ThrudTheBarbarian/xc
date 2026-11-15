#!/bin/bash
# literal-overflow.sh — an integer literal past u64 is an error (#292). The
# self-hosted lexer wrapped it mod 2^64 and the other saturated it, both with
# no word. Both compilers take u64's largest value (decimal and hex) and
# refuse one past it, and longer decimal, hex, $hex and %binary literals,
# with "does not fit in 64 bits".
#
#   bash tests/driver/literal-overflow.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
src() { printf '#import "Stdio.xc"\ni32 main(void) { u64 b = %s; Stdio.printf("%%llu\\n", b); return 0; }\n' "$1" > "$W/t.xc"; }
BIG=%11111111111111111111111111111111111111111111111111111111111111111
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    n=$(basename "$c")
    for ok in 18446744073709551615 0xFFFFFFFFFFFFFFFF; do
        src "$ok"
        "$c" -q -H . -o "$W/t" "$W/t.xc" > "$W/e" 2>&1 || { echo "FAIL $n: $ok refused: $(head -c 200 "$W/e")"; fail=1; }
    done
    for bad in 18446744073709551616 99999999999999999999 0x10000000000000000 '$1FFFFFFFFFFFFFFFF' "$BIG"; do
        src "$bad"
        if "$c" -q -H . -o "$W/t" "$W/t.xc" > "$W/e" 2>&1; then
            echo "FAIL $n: $bad built"; fail=1
        elif ! grep -q "does not fit in 64 bits" "$W/e"; then
            echo "FAIL $n: $bad refused without the message: $(head -c 200 "$W/e")"; fail=1
        fi
    done
done
[ $fail = 0 ] && echo "literal-overflow: ok"
exit $fail
