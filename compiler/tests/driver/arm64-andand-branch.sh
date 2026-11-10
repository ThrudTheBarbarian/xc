#!/bin/bash
# arm64-andand-branch.sh — a fused `a && b` branch whose edges have no copies
# to make branches straight to its blocks: the first test to the FALSE block,
# the second to the TRUE one, with no stub labels between. mandelbrot's escape
# loop then ends in one conditional back edge (`b.lo` to the loop head) where
# it had a conditional exit to a stub and an unconditional `b`. On a Pi 5 the
# old form ran 6% slower or not by the instructions laid out before the loop;
# the new one runs at one speed, faster than either.
# Both compilers, the same assembly.
#     bash tests/driver/arm64-andand-branch.sh
cd "$(dirname "$0")/../.."
W=$(mktemp -d /tmp/andand-branch.XXXX)
trap 'rm -rf "$W"' EXIT
rc=0
for c in xcc xcc-xc; do
    [ -x "bin/osx/$c" ] || continue
    for t in arm64-macos arm64-linux; do
        s="$W/$c.$t.s"
        bin/osx/$c -q -H . -O3 -fno-bounds-check -A $t -S -o "$s" ../benchmark/par/mandelbrot.xc \
            || { echo "FAIL andand-branch: $c -A $t does not build"; rc=1; continue; }
        # The vector escape loop: from its head to its exit block.
        body=$(awk '/^LParImpl\$0\$run_bb_4_header_esc:$/{on=1} /^LParImpl\$0\$run_bb_4_exit_esc:$/{on=0} on' "$s")
        if [ -z "$body" ]; then
            echo "FAIL andand-branch: $c -A $t: no vector escape loop"; rc=1; continue
        fi
        if printf '%s\n' "$body" | grep -q '_sc[12]_'; then
            echo "FAIL andand-branch: $c -A $t: a stub label is left in the escape loop"; rc=1
        fi
        if ! printf '%s\n' "$body" | grep -q '^    b\.lo LParImpl\$0\$run_bb_4_header_esc$'; then
            echo "FAIL andand-branch: $c -A $t: the vector loop's back edge is not one b.lo"; rc=1
        fi
    done
done
for t in arm64-macos arm64-linux; do
    if [ -f "$W/xcc.$t.s" ] && [ -f "$W/xcc-xc.$t.s" ] && ! cmp -s "$W/xcc.$t.s" "$W/xcc-xc.$t.s"; then
        echo "FAIL andand-branch: the two compilers' $t assembly differs"; rc=1
    fi
done
[ $rc = 0 ] && echo "arm64-andand-branch: ok"
exit $rc
