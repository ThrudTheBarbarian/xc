#!/bin/bash
# vec-iota-unroll.sh — an unrolled vector reduction over f(i + seed) builds its
# lane-index vector once per iteration (2026-11-01).
#
# The reduction unroller's copy k used to broadcast i + k*vw and add the iota
# and the seed again, every copy: zero, move, broadcast and two adds per
# block (call_depth). Copy k now takes copy 0's index vector, the seed's add
# folded in, plus a constant k*vw splat made once in the preheader: one add.
#
# Checked, for tests/fixtures/vec_iota_unroll.xc: the two compilers' x86-64
# assembly is the same at avx2 and avx512; at avx512 the first loop
# (unrolled twice) broadcasts once per iteration, not once per copy (the 0.9
# build: twice);
# and the program built for this host prints the right sums.
#
#   bash tests/driver/vec-iota-unroll.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/vec_iota_unroll.xc
fail=0
for l in avx2 avx512; do
    "$REF" -q -H . -A x86_64 -O3 -msimd=$l -S -o "$W/r.s" "$F" > "$W/e" 2>&1 || { echo "FAIL vec-iota-unroll: $l: $(basename "$REF") does not build it"; fail=1; continue; }
    "$XC" -q -H . -A x86_64 -O3 -msimd=$l -S -o "$W/x.s" "$F" > "$W/e" 2>&1 || { echo "FAIL vec-iota-unroll: $l: $(basename "$XC") does not build it"; fail=1; continue; }
    cmp -s "$W/r.s" "$W/x.s" || { echo "FAIL vec-iota-unroll: $l: the two compilers' assembly differs"; fail=1; }
    # Broadcasts from the first loop's body label to its back branch, at
    # avx512: avx2's 16 registers re-splat constants inside the loop, which
    # this count would take for index broadcasts.
    [ $l = avx512 ] || continue
    n=$(awk '/^main:/{f=1} f' "$W/x.s" | awk '/^\.L_main_bb_1_for_body:/{f=1} f && /vpbroadcastd/{n++} f && /(jb|jmp)	\.L_main_bb_1_for_body$/{print n+0; exit}')
    [ "$n" = 1 ] || { echo "FAIL vec-iota-unroll: $l: $n broadcasts in the unrolled loop (want 1)"; fail=1; }
done
"$XC" -q -H . -O3 -o "$W/p" "$F" > "$W/e" 2>&1 || { echo "FAIL vec-iota-unroll: no host build"; exit 1; }
got=$("$W/p")
[ "$got" = "$(cat tests/fixtures/vec_iota_unroll.expected.out)" ] || { echo "FAIL vec-iota-unroll: prints '$got'"; fail=1; }
[ $fail = 0 ] && echo "vec-iota-unroll: ok"
exit $fail
