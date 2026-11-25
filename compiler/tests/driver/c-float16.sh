#!/bin/bash
# c-float16.sh — C's _Float16 and __bf16 through xcc's C path. tests/c/float16.c
# must print what clang's build of it prints: arithmetic rounded per
# operation, conversions to and from integers, float and double (ties, the
# subnormals, overflow to infinity), comparisons with NaN, a struct of halves,
# printf given halves, and the C calling convention between xcc's functions
# and clang's (a variadic definition stays clang's; it takes eleven halves from
# xcc's code and passes them on to xcc's). xcc must read every function but
# that one, and the loop over _Float16 arrays must become a par block.
#
#   bash tests/driver/c-float16.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
command -v clang > /dev/null || { echo "--- c-float16: skipped (no clang) ---"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
clang -O2 -o "$W/ref" tests/c/float16.c || { echo "FAIL c-float16: clang does not build it"; exit 1; }
want=$("$W/ref")
XC_C_TRACE=1 XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O2 -o "$W/f" tests/c/float16.c 2> "$W/trace" || { echo "FAIL c-float16: does not build"; cat "$W/trace"; exit 1; }
got=$("$W/f")
[ "$got" = "$want" ] || { echo "FAIL c-float16: output differs from clang's"; diff <(echo "$want") <(echo "$got"); fail=1; }
left=$(sed -n 's/^xcc: C path: left to clang: //p' "$W/trace" | tr '\n' ' ')
[ "$left" = "@cl_many " ] || { echo "FAIL c-float16: left to clang: '$left', want only @cl_many"; fail=1; }
got1=$(XC_PAR=cpu XC_PAR_THREADS=1 "$W/f")
[ "$got1" = "$want" ] || { echo "FAIL c-float16: one thread prints otherwise"; fail=1; }
grep -q '^outline: madd:[0-9]*: outlined, a block' "$W/trace" || { echo "FAIL c-float16: madd's loop is not a par block"; fail=1; }
[ $fail = 0 ] && echo "c-float16: ok"
exit $fail
