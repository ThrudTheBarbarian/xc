#!/bin/bash
# arm64-loop-align.sh — the target row's loop-align: on the Apple rows each
# loop head (a block a later or the same block branches back to) is aligned
# to 32 bytes, and on arm64 Linux it is not (on an M3 Max the boundary took
# sort_small 14% and sieve 4.5% faster; on a Pi 5 the suite came out even).
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
            arm64-macos) [ "$n" -gt 0 ] && [ -z "$bad" ] || { echo "FAIL loop-align: $c -A $t: $n aligned heads ${bad:+(one before '$bad')}"; rc=1; } ;;
            arm64-linux) [ "$n" = 0 ] || { echo "FAIL loop-align: $c -A $t aligned $n loop heads"; rc=1; } ;;
        esac
    done
done
if [ -f "$W/xcc.arm64-macos.s" ] && [ -f "$W/xcc-xc.arm64-macos.s" ] && ! cmp -s "$W/xcc.arm64-macos.s" "$W/xcc-xc.arm64-macos.s"; then
    echo "FAIL loop-align: the two compilers' arm64-macos assembly differs"; rc=1
fi
[ $rc = 0 ] && echo "arm64-loop-align: ok"
exit $rc
