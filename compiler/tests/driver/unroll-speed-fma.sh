#!/bin/bash
# unroll-speed-fma.sh — a loop under :goal(speed) that the unroller unrolls
# whole keeps its fused multiply-adds (#24). Fusion finds speed code by its
# loop's header, which full unrolling removes; the unroller marks the copies
# as fusion would have. Read from arm64 -S: the unrolled body fuses (fmadd),
# and the same loop under :goal(accuracy) does not. --par-style=cpu keeps it
# a loop (a float sum under :goal(speed) would otherwise become a par block).
#
#   bash tests/driver/unroll-speed-fma.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
for g in speed accuracy; do
cat > "$W/$g.xc" <<SRC
#import "Stdio.xc"
float a[64];
float b[64];
float acc(u32 base)
{
    float s = 0.0f;
    for (u32 k = (u32)0; k < (u32)4; k++) :goal($g)
        s = s + a[base + k] * b[base + k];
    return s;
}
i32 main(void)
{
    for (u32 i in 0..64) { a[i] = (float)i * 0.5f; b[i] = 1.5f; }
    Stdio.printf("%d\n", (i32)acc((u32)8));
    return 0;
}
SRC
"$XC" -q -A arm64 -H . -O2 --par-style=cpu -S -o "$W/$g.s" "$W/$g.xc" > "$W/$g.err" 2>&1 || { echo "FAIL unroll-speed-fma: $g does not build"; head -3 "$W/$g.err"; exit 1; }
# The function's body only: from its label to the next global one.
awk '/^_acc:/{p=1;next} p&&/^_[A-Za-z0-9_$]*:$/{exit} p' "$W/$g.s" > "$W/$g.fn"
fm=$(grep -cE '^[[:space:]]+fmadd' "$W/$g.fn")
br=$(grep -cE '^[[:space:]]+b\.[a-z]+[[:space:]]' "$W/$g.fn")
case $g in
    speed)    [ "$fm" -ge 3 ] || { echo "  FAIL: the unrolled speed loop fuses $fm times, wanted 3 or more"; fail=1; }
              [ "$br" = 0 ] || { echo "  FAIL: the speed loop was not unrolled ($br branches)"; fail=1; } ;;
    accuracy) [ "$fm" = 0 ] || { echo "  FAIL: the accuracy loop fuses ($fm times)"; fail=1; } ;;
esac
done
[ $fail = 0 ] && echo "--- unroll-speed-fma: pass ---" || { echo "--- unroll-speed-fma: FAIL ---"; exit 1; }
