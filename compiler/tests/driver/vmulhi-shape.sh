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
# The merge of the two products then depends on the width (2026-11-04): SSE
# gathers the odd dwords (shufps 0xDD, pshufd 0xD8); AVX2 shifts the even
# products' high halves down and blends (psrlq 32, vpblendd 0xAA, no
# shuffle); AVX-512 permutes from both products at once (vpermi2d, its lane
# order the constant __xc_vmulhi_idx). int_muldiv on Zen 5: 0.419 -> 0.379 s
# (AVX-512), 0.825 -> 0.797 s (AVX2).
#
# Checked, for tests/fixtures/vec_udiv_const.xc at each SIMD level: the two
# compilers' assembly is the same; every pmuludq pairs with one 0xF5; each
# high product has exactly one merge, and the level's own form is there;
# every `psrlq …, 32` is an AVX2 merge's (0xB1 is no witness: the sums'
# reductions use it); and the lane-order constant is there exactly when
# vpermi2d is.
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
    bl=$(grep -c 'vpblendd.*, 0xAA$' "$W/x.s"); pm=$(grep -c 'vpermi2d' "$W/x.s"); idx=$(grep -c '^__xc_vmulhi_idx:' "$W/x.s")
    [ "$mul" -gt 0 ] || { echo "FAIL vmulhi-shape: $l: the loops did not vectorise (no pmuludq)"; fail=1; continue; }
    [ "$mul" = $((f5 * 2)) ] || { echo "FAIL vmulhi-shape: $l: $mul pmuludq for $f5 shuffles (want two per shuffle)"; fail=1; }
    [ $((dd + bl + pm)) = "$f5" ] || { echo "FAIL vmulhi-shape: $l: $((dd + bl + pm)) merges for $f5 high products"; fail=1; }
    [ "$sh" = "$bl" ] || { echo "FAIL vmulhi-shape: $l: $sh psrlq 32 for $bl AVX2 merges"; fail=1; }
    case $l in
        base) [ "$dd" -gt 0 ] && [ $((bl + pm)) = 0 ] || { echo "FAIL vmulhi-shape: base: want only shufps 0xDD merges ($dd/$bl/$pm)"; fail=1; } ;;
        avx2) [ "$bl" -gt 0 ] && [ "$pm" = 0 ] || { echo "FAIL vmulhi-shape: avx2: want vpblendd merges and no vpermi2d ($bl/$pm)"; fail=1; } ;;
        avx512) [ "$pm" -gt 0 ] || { echo "FAIL vmulhi-shape: avx512: no vpermi2d merge"; fail=1; } ;;
        auto) [ "$dd" -gt 0 ] && [ "$bl" -gt 0 ] && [ "$pm" -gt 0 ] || { echo "FAIL vmulhi-shape: auto: want all three forms ($dd/$bl/$pm)"; fail=1; } ;;
    esac
    [ $((pm > 0)) = "$idx" ] || { echo "FAIL vmulhi-shape: $l: $pm vpermi2d and $idx lane-order constants"; fail=1; }
done
[ $fail = 0 ] && echo "vmulhi-shape: ok"
exit $fail
