#!/bin/bash
# eqexit.sh — loops that leave when their test is true. clang at -O1 ends a
# counted loop with `icmp eq i, n` and branches to the exit on true, where
# xc's own loops continue on true. The variable-trip unroller wired its
# copies for the second kind only, so such a loop stopped after one element.
# The IR is clang's own (read through XC_C_LL), compared with clang's build.
# Skipped where there is no clang, or where clang writes no such exit.
#
#   bash tests/par/eqexit.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version >/dev/null 2>&1; then
    echo "--- eqexit: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/axpy.c" <<'C'
#include <stdio.h>
__attribute__((noinline)) void axpy(float a, const float *x, float *y, unsigned long n)
{
    for (unsigned long i = 0; i != n; i++)
        y[i] = a * x[i] + y[i];
}
float x[1000], y[1000];
int main(void)
{
    for (int i = 0; i < 1000; i++) {
        x[i] = i;
        y[i] = 1;
    }
    axpy(2.0f, x, y, 1000);
    double t = 0;
    for (int i = 0; i < 1000; i++)
        t += y[i];
    printf("%.1f\n", t);
    return 0;
}
C
clang -O1 -fno-unroll-loops -fno-vectorize -fno-slp-vectorize -fno-discard-value-names -gline-tables-only \
    -mllvm -rotation-max-header-size=0 -mllvm -indvars-widen-indvars=false -S -emit-llvm -o "$W/axpy.ll" "$W/axpy.c" 2>/dev/null
if ! grep -q 'icmp eq i64' "$W/axpy.ll"; then
    echo "--- eqexit: skipped (this clang writes no eq exit) ---"
    exit 0
fi
clang -O2 -o "$W/ref" "$W/axpy.c"
want=$("$W/ref")
for o in O0 O2 O3; do
    XC_C_LL="$W/axpy.ll" "$XC" -q -$o --par-style=cpu -H . -o "$W/p" "$W/axpy.c" > "$W/b" 2>&1 \
        || { echo "FAIL eqexit: -$o does not build"; head -3 "$W/b"; fail=1; continue; }
    got=$("$W/p")
    [ "$got" = "$want" ] || { echo "FAIL eqexit: -$o gives $got, clang's $want"; fail=1; }
done
[ $fail = 0 ] && echo "--- eqexit: pass ---" || echo "--- eqexit: FAIL ---"
exit $fail
