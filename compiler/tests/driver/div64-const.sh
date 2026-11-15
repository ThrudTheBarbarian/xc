#!/bin/bash
# div64-const.sh — 64-bit division by a constant is a magic-number multiply
# (#309), as 32-bit division already was: umulh/smulh on arm64 and a 64-bit
# mul/imul on x86-64 instead of sdiv/udiv or div/idiv. A loop of
# i64 / 7, i64 % 1000000007 and u64 / 10 on Zen 5: 0.83 -> 0.22 s.
#
# tests/fixtures/div64_const.xc checks every constant against the same
# division by an opaque value; here, `x / 7` and `x % 1000000007` (inlined into
# main) use no divide instruction on either target, the two compilers print the
# same code, and the fixture runs clean where the target is the host.
#
#   bash tests/driver/div64-const.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
printf 'i64 f(i64 x) { return x / (i64)7; }\nu64 g(u64 x) { return x %% (u64)1000000007; }\ni32 main(i32 argc, u8** argv) { return (i32)(f((i64)argc) + (i64)g((u64)argc)); }\n' > "$W/s.xc"
for A in arm64 x86_64; do
    for c in "$REF" "$XC"; do
        [ -x "$c" ] || continue
        "$c" -q -O2 -A $A -H . -S -o "$W/$A.$(basename "$c").s" "$W/s.xc" || { echo "FAIL $(basename "$c") $A: no assembly"; fail=1; }
    done
    if [ -s "$W/$A.xcc.s" ] && [ -s "$W/$A.xcc-xc.s" ] && ! cmp -s "$W/$A.xcc.s" "$W/$A.xcc-xc.s"; then echo "FAIL: the two compilers' $A code differs"; fail=1; fi
    S="$W/$A.$(basename "$XC").s"
    body=$(awk '$0 == "_main:" || $0 == "main:" {on = 1; next} on && /^[_A-KM-Za-z$][^ \t]*:$/ {on = 0} on' "$S")
    if [ $A = arm64 ]; then
        echo "$body" | grep -qE '^\s+[su]div\s' && { echo "FAIL arm64: main divides"; fail=1; }
        n=$(echo "$body" | grep -cE '^\s+[su]mulh\s')
        [ "$n" = 2 ] || { echo "FAIL arm64: main has $n umulh/smulh, want 2"; fail=1; }
    else
        echo "$body" | grep -qE $'^\t(i?div)\t' && { echo "FAIL x86-64: main divides"; fail=1; }
        n=$(echo "$body" | grep -cE $'^\t(i?mul)\trcx$')
        [ "$n" = 2 ] || { echo "FAIL x86-64: main has $n 64-bit mul/imul, want 2"; fail=1; }
    fi
done
if [ "$PLAT" = osx ] || [ "$(uname -m)" = x86_64 ]; then
    "$XC" -q -O0 -H . -o "$W/t" tests/fixtures/div64_const.xc && got=$("$W/t")
    [ "${got:-}" = "$(cat tests/fixtures/div64_const.expected.out)" ] || { echo "FAIL: the fixture at -O0 printed '${got:-}'"; fail=1; }
fi
[ $fail = 0 ] && echo "div64-const: ok"
exit $fail
