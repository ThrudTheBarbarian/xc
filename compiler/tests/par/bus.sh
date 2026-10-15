#!/bin/bash
# bus.sh — auto does not stack the CPU with a GPU that shares its memory bus
# on a bandwidth-bound block (from 0.8.1), on this host's GPU.
#
# A saxpy over `simd:` arrays is bandwidth-bound (4 ops, 12 bytes an item).
# On a unified-memory GPU (Apple silicon, an integrated GPU) auto measures the
# CPU and the GPU but not "all devices": the two draw on one bus, so together
# they move no more bytes a second than the faster alone. On a discrete card
# the earlier rule keeps the block on the CPU without a GPU trial at all.
# Nothing to check where the host has no GPU.
#
#   bash tests/par/bus.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/bus.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
#define SIZE (32 * 1024 * 1024)
i32 main(void)
    {
    simd: u32* xs = new u32[SIZE];
    simd: u32* ys = new u32[SIZE];
    for (u32 i in 0..SIZE)
        {
        xs[i] = i * (u32)2654435761;
        ys[i] = i;
        }
    for (u32 rep in 0..8)
        {
        par saxpy
            {
            for (u32 i in 0..SIZE)
                ys[i] = (u32)3 * xs[i] + ys[i];
            }
        }
    u32 sum = (u32)0;
    for (u32 i in 0..SIZE)
        sum = sum + ys[i];
    Stdio.printf("%u\n", sum);
    return (i32)0;
    }
XC
"$XC" -q -H . -O2 "$W/bus.xc" -o "$W/bus" >"$W/build" 2>&1 || { echo "FAIL bus: build"; head -3 "$W/build"; exit 1; }
export XCC_SETTINGS_DIR="$W/st"; mkdir -p "$XCC_SETTINGS_DIR"
XC_PAR_REPORT=1 "$W/bus" > "$W/r1" 2>&1
if ! grep -q "hardware key" "$W/r1" || grep -q "hardware key [0-9a-f]* (|" "$W/r1"; then
    echo "SKIP bus: no GPU on this host"; exit 0
fi
fail=0
tail -1 "$W/r1" | grep -q '^[0-9][0-9]*$' || { echo "FAIL bus: the program did not finish"; tail -3 "$W/r1"; fail=1; }
if grep -q "across a bus" "$W/r1"; then
    : # a discrete card: the block never reaches the GPU trial (0.8's rule)
elif grep -q "auto does not try all devices" "$W/r1"; then
    if grep -q "us on all devices" "$W/r1"; then
        echo "FAIL bus: all devices was measured on a shared bus"; grep "all devices" "$W/r1"; fail=1
    fi
    grep -q "auto picks the" "$W/r1" || { echo "FAIL bus: auto never decided"; tail -5 "$W/r1"; fail=1; }
else
    echo "FAIL bus: neither rule applied"; grep "saxpy" "$W/r1" | grep -v "items" | head -8; fail=1
fi
[ "$fail" = 0 ] && echo "PASS bus"
exit $fail
