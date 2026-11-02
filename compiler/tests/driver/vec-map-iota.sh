#!/bin/bash
# vec-map-iota.sh — a map loop that stores a value computed from its own
# induction variable vectorises, lane l of the iv holding i + l (2026-11-02).
#
# The map vectoriser took its lane values only from iv-indexed loads, so
# `a[i] = ((i * K) ^ x) + s` (sort_small's fill: no load at all) and
# `b[i] = a[i] + i` stayed scalar, while a reduction over i already used the
# lane-index vector. Now the iv is a lane value in maps too: the lane-index
# table is loaded once in the preheader and VSplat(i) + it is i's vector. In
# the port a hoisted constant splat is also read 64-bit: 2654435761 came out
# as a negative immediate.
#
# Checked, for tests/fixtures/vec_map_iota.xc at -O3 on x86-64 and arm64: the
# lane-index table is used (the loops vectorised), the two compilers'
# assembly is the same, and the program built for this host prints the
# expected values (three loops, one with a scalar remainder).
#
#   bash tests/driver/vec-map-iota.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/vec_map_iota.xc
fail=0
for t in x86_64 arm64; do
    "$REF" -q -H . -A $t -O3 -S -o "$W/ref.$t.s" "$F" || { echo "FAIL: $REF did not build $F for $t"; fail=1; continue; }
    "$XC" -q -H . -A $t -O3 -S -o "$W/xc.$t.s" "$F" || { echo "FAIL: $XC did not build $F for $t"; fail=1; continue; }
    k=$(grep -c '__xtv_iota' "$W/ref.$t.s")
    [ "$k" -gt 0 ] && echo "ok: $t: the lane-index table is used ($k references)" \
        || { echo "FAIL: $t: no lane-index table: the iota maps stayed scalar"; fail=1; }
    cmp -s "$W/ref.$t.s" "$W/xc.$t.s" && echo "ok: $t: the two compilers' assembly is the same" \
        || { echo "FAIL: $t: the two compilers' assembly differs"; fail=1; }
done
"$XC" -q -H . -O3 -o "$W/run" "$F" && out=$("$W/run") || out="(no run)"
want=$(cat tests/fixtures/vec_map_iota.expected.out)
[ "$out" = "$want" ] && echo "ok: prints $out" || { echo "FAIL: printed '$out', want '$want'"; fail=1; }
[ $fail -eq 0 ] && echo "vec-map-iota: ok"
exit $fail
