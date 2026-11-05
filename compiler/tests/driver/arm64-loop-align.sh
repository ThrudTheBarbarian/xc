#!/bin/bash
# arm64-loop-align.sh — the target row's loop-align: on the Apple rows and on
# arm64 Linux each loop head (a block a later or the same block branches back
# to) is aligned to 32 bytes (on an M3 Max the boundary took sort_small 14%
# and sieve 4.5% faster). On a Pi 5 the suite came out even on average, but
# an unaligned loop ran at whatever speed its address gave it: the same
# poly_dispatch loop took 1.94 s or 2.68 s by where the link put it, and
# 1.95 s either way aligned (0.9.4).
# Both compilers, the same assembly.
#     bash tests/driver/arm64-loop-align.sh
cd "$(dirname "$0")/../.."
W=$(mktemp -d /tmp/loop-align.XXXX)
trap 'rm -rf "$W"' EXIT
rc=0
for c in xcc xcc-xc; do
    [ -x "bin/osx/$c" ] || continue
    for t in arm64-macos arm64-linux; do
        bin/osx/$c -q -H . -O3 -A $t -I ../benchmark/src -S -o "$W/$c.$t.s" ../benchmark/src/sort_small.xc || { echo "FAIL loop-align: $c -A $t does not build"; rc=1; continue; }
        # Each `.p2align 5` must sit right before a block label.
        n=$(grep -c '^    \.p2align 5$' "$W/$c.$t.s")
        bad=$(awk '/^    \.p2align 5$/{getline l; if (l !~ /^L.*:$/) print l}' "$W/$c.$t.s" | head -1)
        case $t in
            *) [ "$n" -gt 0 ] && [ -z "$bad" ] || { echo "FAIL loop-align: $c -A $t: $n aligned heads ${bad:+(one before '$bad')}"; rc=1; } ;;
        esac
    done
done
for t in arm64-macos arm64-linux; do
    if [ -f "$W/xcc.$t.s" ] && [ -f "$W/xcc-xc.$t.s" ] && ! cmp -s "$W/xcc.$t.s" "$W/xcc-xc.$t.s"; then
        echo "FAIL loop-align: the two compilers' $t assembly differs"; rc=1
    fi
done
[ $rc = 0 ] && echo "arm64-loop-align: ok"
exit $rc
