#!/bin/bash
# x86-vload-fold.sh — a vector load read by one integer binop at 32 or 64
# bytes is the binop's memory operand (#42, array_sum). array_sum's inner
# loop loaded each vector (vmovdqu32) and xored it in a second op, where clang
# reads memory in the vpxord. Folded only in a block with no vector store and
# not into vpmulld: mem_copy, array_map and matrix_mul ran 1-4% slower folded
# on Zen 5. One thread on Zen 5: array_sum 215 -> 202 ms.
#
# array_sum's AVX2 and AVX-512 loops xor from memory, mem_copy's loops keep
# their loads, the two compilers print the same code, and on an x86-64 Linux host
# array_sum gives its checksum.
#
#   bash tests/driver/x86-vload-fold.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
D=../benchmark/src
[ -f "$D/array_sum.xc" ] || { echo "x86-vload-fold: no benchmark sources, skipped"; exit 0; }
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for n in array_sum mem_copy; do
    for c in "$REF" "$XC"; do
        [ -x "$c" ] || continue
        "$c" -q -A x86_64 -O2 -H . -I "$D" -S -o "$W/$n.$(basename "$c").s" "$D/$n.xc" || { echo "FAIL $c: no assembly for $n"; fail=1; }
    done
    if [ -s "$W/$n.xcc.s" ] && [ -s "$W/$n.xcc-xc.s" ] && ! cmp -s "$W/$n.xcc.s" "$W/$n.xcc-xc.s"; then echo "FAIL: the two compilers' code for $n differs"; fail=1; fi
done
S="$W/array_sum.$(basename "$XC").s"
z=$(grep -cE $'^\tvpxord\tzmm[0-9]+, zmm[0-9]+, zmmword ptr' "$S")
y=$(grep -cE $'^\tvpxor\tymm[0-9]+, ymm[0-9]+, ymmword ptr' "$S")
[ "$z" -ge 4 ] && [ "$y" -ge 4 ] || { echo "FAIL: array_sum xors from memory $z times at AVX-512 and $y at AVX2, want 4 or more each"; fail=1; }
M="$W/mem_copy.$(basename "$XC").s"
m=$(awk '/^\.L.*_for_body/ {on = 1; next} /^\.L/ {on = 0} on && /^\tvpaddd\t[yz]mm[0-9]+, [yz]mm[0-9]+, [yz]mmword ptr/ {k++} END {print k + 0}' "$M")
[ "$m" = 0 ] || { echo "FAIL: mem_copy's loops add from memory $m times, want their loads kept (they store)"; fail=1; }
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; then
    "$XC" -q -A x86_64 -O2 -H . -I "$D" -o "$W/array_sum" "$D/array_sum.xc" || { echo "FAIL: build"; fail=1; }
    got=$(XC_PAR=cpu XC_PAR_THREADS=1 "$W/array_sum" x 2>/dev/null | cut -d' ' -f1)
    [ "$got" = 624558080 ] || { echo "FAIL: array_sum gives $got, want 624558080"; fail=1; }
fi
[ $fail = 0 ] && echo "x86-vload-fold: ok"
exit $fail
