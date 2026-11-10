#!/bin/bash
# vec-iota-affine.sh — a map loop that stores an affine function of its
# induction variable, i * K + D, keeps (i + l) * K + D in a vector stepped by
# an add: its body has no vector multiply.
#
# The vectoriser took the iv as a lane value, VSplat(i) plus the lane-index
# table, made that an induction vector stepped by splat(lanes), and then
# multiplied it by splat(K) in every group (sort_small's fill
# `a[i] = ((i * K) ^ x) + s`), with the loop-invariant `splat(r) * splat(K2)`
# made once per unrolled copy. The induction vector now carries the multiply
# and steps by splat(lanes * K), and the unroller shares invariant vector
# arithmetic between its copies.
#
# Checked, for tests/fixtures/vec_iota_affine.xc at -O3 on arm64 and x86-64
# (with its AVX2 and AVX-512 clones): the loops vectorised, no loop body holds
# a vector multiply, the two compilers' assembly is the same, and the program
# built for this host prints the scalar values.
#
#   bash tests/driver/vec-iota-affine.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/vec_iota_affine.xc
fail=0
for t in arm64 x86_64; do
    "$REF" -q -H . -A $t -O3 -S -o "$W/ref.$t.s" "$F" || { echo "FAIL: $REF did not build $F for $t"; fail=1; continue; }
    "$XC" -q -H . -A $t -O3 -S -o "$W/xc.$t.s" "$F" || { echo "FAIL: $XC did not build $F for $t"; fail=1; continue; }
    k=$(grep -c '__xtv_iota' "$W/ref.$t.s")
    [ "$k" -gt 0 ] && echo "ok: $t: the lane-index table is used ($k references)" \
        || { echo "FAIL: $t: no lane-index table: the loops stayed scalar"; fail=1; }
    # Vector multiplies between a loop-body label and the next label.
    m=$(awk '/^[._A-Za-z0-9$]*for_body[A-Za-z0-9_$]*:/ { inb = 1; next }
             /^[._A-Za-z0-9$]*:/ { inb = 0 }
             inb && /^[ \t]+(mul|pmulld|vpmulld)[ \t]+.*(v[0-9]+\.4s|xmm|ymm|zmm)/ { n++ }
             END { print n + 0 }' "$W/ref.$t.s")
    [ "$m" -eq 0 ] && echo "ok: $t: no vector multiply in a loop body" \
        || { echo "FAIL: $t: $m vector multiplies in loop bodies"; fail=1; }
    cmp -s "$W/ref.$t.s" "$W/xc.$t.s" && echo "ok: $t: the two compilers' assembly is the same" \
        || { echo "FAIL: $t: the two compilers' assembly differs"; fail=1; }
done
"$XC" -q -H . -O3 -o "$W/run" "$F" && out=$("$W/run") || out="(no run)"
want=$(cat tests/fixtures/vec_iota_affine.expected.out)
[ "$out" = "$want" ] && echo "ok: prints $out" || { echo "FAIL: printed '$out', want '$want'"; fail=1; }
[ $fail -eq 0 ] && echo "vec-iota-affine: ok"
exit $fail
