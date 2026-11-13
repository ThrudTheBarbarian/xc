#!/bin/bash
# fma-select.sh — a float select whose arm is a fused multiply-add (#193):
# perlin's grad, `(g & 2) != 0 ? 0.0f - 2.0f * v : 2.0f * v`, in C (which
# fuses like clang). On x86-64 the select computed that arm after its branch
# while the pair had fused it away, so the AVX2 copy read a product never
# made. Every h must match clang's -O2 build, in xcc's default copy, in
# XC_SIMD=base and, on an x86-64 host with AVX2, in XC_SIMD=avx2; plain and
# lifted. Skipped where there is no clang.
#
#   bash tests/par/fma-select.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version >/dev/null 2>&1; then
    echo "--- fma-select: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/g.c" <<'C'
#include <stdio.h>
static float grad(unsigned h, float x, float y)
{
    unsigned g = h & 7;
    float u = g < 4 ? x : y;
    float v = g < 4 ? y : x;
    float a = (g & 1) != 0 ? 0.0f - u : u;
    float b = (g & 2) != 0 ? 0.0f - 2.0f * v : 2.0f * v;
    return a + b;
}
int main(int argc, char **argv)
{
    (void)argv;
    float s = 0.0f;
    for (unsigned h = 0; h < 8; h++) {
        float r = grad(h + (unsigned)argc - 1u, 0.25f * (float)argc, 0.75f);
        printf("%u %g\n", h, r);
    }
    for (unsigned i = 0; i < 4096; i++)
        s += grad(i * 2654435761u, (float)(i & 63) * 0.125f, (float)(i >> 6) * 0.0625f);
    printf("sum %g\n", s);
    return 0;
}
C
clang -O2 -o "$W/ref" "$W/g.c" || { echo "FAIL fma-select: clang does not build it"; exit 1; }
want=$("$W/ref")
fail=0
copies=" base"
[ "$(uname -m)" = x86_64 ] && grep -qw avx2 /proc/cpuinfo 2>/dev/null && copies=" base avx2"
for ps in cpu auto; do
    "$XC" -q -O3 --par-style=$ps -H . -o "$W/t.$ps" "$W/g.c" > "$W/b.$ps" 2>&1 \
        || { echo "FAIL fma-select: does not build (--par-style=$ps)"; head -3 "$W/b.$ps"; fail=1; continue; }
    for simd in "" $copies; do
        got=$(XC_SIMD=$simd XC_PAR=cpu "$W/t.$ps")
        [ "$got" = "$want" ] || { echo "FAIL fma-select: --par-style=$ps XC_SIMD=${simd:-default} differs from clang:"; diff <(echo "$want") <(echo "$got") | head -6; fail=1; }
    done
done
[ $fail = 0 ] && echo "--- fma-select: pass ---" || echo "--- fma-select: FAIL ---"
exit $fail
