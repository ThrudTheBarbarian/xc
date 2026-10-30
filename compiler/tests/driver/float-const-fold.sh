#!/bin/bash
# float-const-fold.sh — constants fold in the IR, floats included (2026-10-30)
#
# The C path gets clang's folding before xcc reads its IR and the xc front end
# folds no float constant, so the same loop reached the escape vectoriser in
# two shapes: mandel_deep's par body kept `(float)W` (W a u16 literal) as a
# UIToFp and `1.5f / (float)W` as a division per item, and was not
# vectorised. The simplifier now folds an int-to-float conversion of a
# constant, float + - * / of two constants (in the type's own precision) and
# Neg of an integer constant. Checked on tests/fixtures/float_const_fold.xc:
# its main keeps no FDiv, SIToFp or Neg after optimisation, the two compilers
# write the same assembly, and the program prints what it prints unoptimised.
#
#   bash tests/driver/float-const-fold.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/float_const_fold.xc
fail=0
left=$("$XC" -q -O2 --emit-ir-opt "$F" 2>&1 | awk '/function main\(/,/^  }/' | grep -cE ' = (FDiv|SIToFp|Neg) ')
[ "$left" = 0 ] || { echo "FAIL float-const-fold: $left FDiv/SIToFp/Neg of constants left in main"; fail=1; }
for s in r x; do
    c=$REF; [ $s = x ] && c=$XC
    "$c" -q -O2 -S -o "$W/$s.s" "$F" > "$W/e" 2>&1 || { echo "FAIL float-const-fold: $(basename "$c") does not compile it"; fail=1; }
done
[ $fail = 0 ] && { cmp -s "$W/r.s" "$W/x.s" || { echo "FAIL float-const-fold: the two compilers' assembly differs"; fail=1; }; }
if [ $fail = 0 ] && [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
    "$XC" -q -O2 -o "$W/p" "$F" && "$W/p" | cmp -s - tests/fixtures/float_const_fold.expected.out \
        || { echo "FAIL float-const-fold: the program prints something else"; fail=1; }
fi
[ $fail = 0 ] && echo "float-const-fold: ok"
exit $fail
