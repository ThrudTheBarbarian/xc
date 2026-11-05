#!/bin/bash
# arm64-chain-unroll.sh — a par item loop of independent vector chains,
# v = v * k + c per chain (issue #8): the vectoriser leaves the rounds loop
# rotated, and on arm64 it is unrolled twice and ordered chain by chain, so
# each step is `orr` + `fmla` into a register other than its multiplicand —
# not the product through the v16 scratch and a copy back.
#
#   1. the rounds loop holds two fmla per chain and no `orr vN, v16` copy;
#   2. both compilers write the same assembly (arm64 Linux and macOS);
#   3. built for this Mac, it prints what the same rounds print when the loop
#      is not unrolled (an odd trip, 511 rounds and the last one after it):
#      the same fused steps in the same order, so the same bits.
#
#   bash tests/driver/arm64-chain-unroll.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
REF=${REF:-bin/$PLAT/xcc}; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d /tmp/arm64-chain-unroll.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0

cat > "$W/c.xc" <<'EOF'
#import "Stdio.xc"
#import "Par.xc"
#define N 4096
#define ROUNDS 512
float out[N];
i32 main(void)
    {
    par chains
        {
        for (u32 i in 0..N)
            {
            float x = (float)(i & (u32)255) * 0.001f;
            float v0 = x; float v1 = x + 0.1f; float v2 = x + 0.2f; float v3 = x + 0.3f;
            for (u32 k in 0..ROUNDS)
                {
                v0 = v0 * 0.9999f + 0.0001f; v1 = v1 * 0.9999f + 0.0001f;
                v2 = v2 * 0.9999f + 0.0001f; v3 = v3 * 0.9999f + 0.0001f;
                }
            out[i] = v0 + v1 + v2 + v3;
            }
        }
    float s = 0.0f;
    for (u32 i in 0..N) s = s + out[i];
    Stdio.printf("%.3f\n", (double)s);
    return 0;
    }
EOF

# The same arithmetic in a loop of an odd trip, which is not unrolled.
sed -e 's/for (u32 k in 0..ROUNDS)/for (u32 k in 0..ROUNDS - 1)/' \
    -e 's|            out\[i\] = v0 + v1 + v2 + v3;|            v0 = v0 * 0.9999f + 0.0001f; v1 = v1 * 0.9999f + 0.0001f;\
            v2 = v2 * 0.9999f + 0.0001f; v3 = v3 * 0.9999f + 0.0001f;\
            out[i] = v0 + v1 + v2 + v3;|' "$W/c.xc" > "$W/odd.xc"
grep -q 'ROUNDS - 1' "$W/odd.xc" || { echo "FAIL: could not make the odd-trip variant"; exit 1; }

for A in arm64-linux arm64; do
    for C in "$REF" "$XC"; do
        n=$(basename "$C")
        if ! "$C" -q -O2 -A "$A" -S -o "$W/c.$A.$n.s" "$W/c.xc" 2> "$W/err"; then
            echo "FAIL $n -A $A: build"; head -5 "$W/err"; fail=1
        fi
    done
    if ! cmp -s "$W/c.$A.xcc.s" "$W/c.$A.xcc-xc.s"; then
        echo "FAIL -A $A: the two compilers write different assembly"; fail=1
    fi
    # The rounds loop: the block from its label to the exit label.
    awk '/run_bb_[0-9]+_for_header_esc:$/{h++} h==2&&/_for_exit_esc:/{exit} h==2' "$W/c.$A.xcc-xc.s" > "$W/loop.$A"
    f=$(grep -c 'fmla' "$W/loop.$A")
    back=$(grep -c 'orr v[0-9]*\.16b, v16\.16b' "$W/loop.$A")
    [ "$f" = 8 ] || { echo "FAIL -A $A: $f fmla in the rounds loop, not 8 (4 chains, 2 copies)"; fail=1; }
    [ "$back" = 0 ] || { echo "FAIL -A $A: $back copies back from v16"; fail=1; }
done

if [ "$PLAT" = osx ]; then
    for C in "$REF" "$XC"; do
        n=$(basename "$C")
        "$C" -q -O3 -o "$W/odd.$n" "$W/odd.xc" && "$C" -q -O3 -o "$W/o3.$n" "$W/c.xc" || { echo "FAIL $n: build"; fail=1; continue; }
        a=$(XC_PAR=cpu "$W/odd.$n"); b=$(XC_PAR=cpu "$W/o3.$n")
        [ "$a" = "$b" ] || { echo "FAIL $n: the unrolled loop prints $b, the rolled one $a"; fail=1; }
    done
fi
[ $fail = 0 ] && echo "arm64-chain-unroll: ok"
exit $fail
