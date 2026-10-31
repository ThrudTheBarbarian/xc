#!/bin/bash
# mul-distribute.sh — (b + c) * k beside b * k shares one multiply (2026-10-31)
#
# call_depth's inlined leaf(x), leaf(x + 1), leaf(x + 2), leaf(x + 3) each
# multiplied by 3: four vector multiplies a turn where clang has one, and on a
# Raspberry Pi 5 1.26x clang. Simplify now rewrites a product by a constant of
# an add chain, when another product has the same base and constant, as
# b * k + c * k, reusing a b * k made earlier in the block. Checked on
# tests/fixtures/mul_distribute.xc: main keeps 4 multiplies (0.89: 14; the
# loop is vectorised, one vector multiply a group of four lanes), the two
# compilers write the same assembly, and the answers are those of -O0.
#
#   bash tests/driver/mul-distribute.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/mul_distribute.xc
fail=0
"$XC" -q -O2 --emit-ir-opt -o "$W/p" "$F" 2> "$W/ir" > /dev/null
n=$(awk '/function main\(/,/^  }/' "$W/ir" | grep -cE ' = V?Mul ')
[ "$n" = 4 ] || { echo "FAIL mul-distribute: main multiplies $n times, want 4"; fail=1; }
for s in r x; do
    c=$REF; [ $s = x ] && c=$XC
    "$c" -q -O2 -S -o "$W/$s.s" "$F" > "$W/e" 2>&1 || { echo "FAIL mul-distribute: $(basename "$c") does not compile it"; fail=1; }
done
[ $fail = 0 ] && { cmp -s "$W/r.s" "$W/x.s" || { echo "FAIL mul-distribute: the two compilers' assembly differs"; fail=1; }; }
if [ $fail = 0 ] && [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
    for o in O0 O2 O3; do
        "$XC" -q -$o -o "$W/p$o" "$F" && "$W/p$o" > "$W/out$o" || { echo "FAIL mul-distribute: -$o build fails"; fail=1; }
    done
    for o in O0 O2 O3; do
        cmp -s "$W/out$o" tests/fixtures/mul_distribute.expected.out || { echo "FAIL mul-distribute: -$o prints $(cat "$W/out$o")"; fail=1; }
    done
fi
[ $fail = 0 ] && echo "mul-distribute: ok"
exit $fail
