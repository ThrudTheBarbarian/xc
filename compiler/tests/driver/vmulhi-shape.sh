#!/bin/bash
# vmulhi-shape.sh — an x86 vector division by a constant takes its lanes' high
# products in five instructions (2026-11-01).
#
# VMulHi (the high half of a 32x32 product, which every u32 division by a
# constant becomes once vectorised) was 8 instructions: two pmuludq, a pshufd
# of each operand, a psrlq of each product, shufps 0x88 and pshufd 0xD8. Taking
# the ODD dwords (shufps 0xDD) makes the two shifts unneeded, and the magic
# number is a splat, which is its own odd-lane shuffle. int_muldiv on a Ryzen 9
# 9955HX: 0.503 -> 0.378 s (clang -march=native 0.335).
#
# Checked, for tests/fixtures/vec_udiv_const.xc at each SIMD level: the two
# compilers' assembly is the same; it has the 0xDD gather and none of the old
# form's `psrlq …, 32` (0xB1 is no witness: the sums' reductions use it); and
# every pmuludq pairs with one 0xF5.
#
#   bash tests/driver/vmulhi-shape.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/vec_udiv_const.xc
fail=0
for l in base avx2 avx512 auto; do
    "$REF" -q -H . -A x86_64 -O3 -msimd=$l -S -o "$W/r.s" "$F" > "$W/e" 2>&1 || { echo "FAIL vmulhi-shape: $l: $(basename "$REF") does not build it"; fail=1; continue; }
    "$XC" -q -H . -A x86_64 -O3 -msimd=$l -S -o "$W/x.s" "$F" > "$W/e" 2>&1 || { echo "FAIL vmulhi-shape: $l: $(basename "$XC") does not build it"; fail=1; continue; }
    cmp -s "$W/r.s" "$W/x.s" || { echo "FAIL vmulhi-shape: $l: the two compilers' assembly differs"; fail=1; }
    mul=$(grep -c 'pmuludq' "$W/x.s"); f5=$(grep -c ', 0xF5$' "$W/x.s"); dd=$(grep -c ', 0xDD$' "$W/x.s"); sh=$(grep -c 'psrlq.*, 32$' "$W/x.s")
    [ "$mul" -gt 0 ] || { echo "FAIL vmulhi-shape: $l: the loops did not vectorise (no pmuludq)"; fail=1; continue; }
    [ "$sh" = 0 ] || { echo "FAIL vmulhi-shape: $l: $sh psrlq 32 (the old form)"; fail=1; }
    [ "$dd" -gt 0 ] || { echo "FAIL vmulhi-shape: $l: no shufps 0xDD"; fail=1; }
    [ "$mul" = $((f5 * 2)) ] || { echo "FAIL vmulhi-shape: $l: $mul pmuludq for $f5 shuffles (want two per shuffle)"; fail=1; }
done
[ $fail = 0 ] && echo "vmulhi-shape: ok"
exit $fail
