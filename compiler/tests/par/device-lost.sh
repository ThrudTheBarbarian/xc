#!/bin/bash
# device-lost.sh — a Vulkan GPU lost in the middle of a run (issue 109).
#
# A lost device never signals the fences of what it was running, and the tile
# queue polled them for ever: the program hung. Now the loss is reported once,
# naming the GPU, the tiles it held go to the other workers or run on the CPU,
# and every later block stays off the GPU; if the GPU was writing an array in
# place, the program stops with a message. XC_PAR_VULKAN_LOSE=<n>
# makes the device read as lost once its n-th submission has gone, as when the
# driver finds the loss after the submission returns. Each case runs under a
# timeout, so a hang fails. A machine without a Vulkan GPU has nothing to
# check and passes.
#
#   bash tests/par/device-lost.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
# lost: a block that writes no array, only a reduction, so a lost GPU's tiles
# can always run again elsewhere. writes: a block that also writes an array,
# which an integrated GPU that imports host memory writes in place.
cat > "$W/lost.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"

#define N (4 * 1024 * 1024)

u32 mix(u32 x)
{
    for (u32 r in 0..32)
    {
        x = x ^ (x >> (u32)15);
        x = x * (u32)0x85ebca77;
        x = x ^ (x << (u32)13);
    }
    return x;
}

i32 main(void)
{
    u32* xs = new u32[N];
    u32 bad = (u32)0;
    for (u32 round in 0..3)
    {
        for (u32 i in 0..N)
            xs[i] = (i + round) * (u32)2654435761;
        u64 sum = (u64)0;
        par lost :reduce(+ sum)
        {
            for (u32 i in 0..N)
                sum = sum + (u64)(mix(xs[i]) & (u32)0xFFFF);
        }
        u64 want = (u64)0;
        for (u32 i in 0..N)
            want = want + (u64)(mix(xs[i]) & (u32)0xFFFF);
        if (sum != want)
            bad = bad + (u32)1;
    }
    Stdio.printf("bad %u\n", bad);
    return (i32)0;
}
XC
cat > "$W/writes.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"

#define N (4 * 1024 * 1024)

u32 mix(u32 x)
{
    for (u32 r in 0..32)
    {
        x = x ^ (x >> (u32)15);
        x = x * (u32)0x85ebca77;
        x = x ^ (x << (u32)13);
    }
    return x;
}

i32 main(void)
{
    u32* xs = new u32[N];
    u32* ys = new u32[N];
    u32 bad = (u32)0;
    for (u32 round in 0..3)
    {
        for (u32 i in 0..N)
        {
            xs[i] = (i + round) * (u32)2654435761;
            ys[i] = (u32)0;
        }
        par writes
        {
            for (u32 i in 0..N)
                ys[i] = mix(xs[i]);
        }
        for (u32 i in 0..N)
            if (ys[i] != mix(xs[i]))
                bad = bad + (u32)1;
    }
    Stdio.printf("bad %u\n", bad);
    return (i32)0;
}
XC
for p in lost writes; do
    "$XC" -q -O2 -o "$W/$p" "$W/$p.xc" > "$W/e" 2>&1 || { echo "FAIL device-lost: $p does not build: $(head -c 300 "$W/e")"; exit 1; }
done
mkdir -p "$W/st"
export XCC_SETTINGS_DIR="$W/st"
XC_PAR=gpu XC_PAR_REPORT=1 timeout 60 "$W/lost" > "$W/probe" 2>&1
if ! grep -q 'Vulkan device is' "$W/probe"; then
    echo "device-lost: ok (no Vulkan GPU here)"
    exit 0
fi

# run <name> <expect: ok|stop> <program> <env...>
run() {
    local name=$1 expect=$2 prog=$3; shift 3
    local t0 t1 rc
    t0=$(date +%s%N)
    env "$@" XC_PAR_TILE_MB=1 timeout 60 "$W/$prog" > "$W/$name.out" 2>&1; rc=$?
    t1=$(date +%s%N)
    local ms=$(( (t1 - t0) / 1000000 ))
    local said
    said=$(grep -c 'was lost' "$W/$name.out")
    if [ $rc = 124 ]; then
        echo "FAIL device-lost $name: hung (killed after 60 s)"; fail=1; return
    fi
    if [ "$expect" = ok ]; then
        if [ $rc != 0 ] || ! grep -qx 'bad 0' "$W/$name.out"; then
            echo "FAIL device-lost $name: rc $rc: $(grep -v '^par:' "$W/$name.out" | head -c 300)"; fail=1; return
        fi
        if [ "$said" != 1 ]; then
            echo "FAIL device-lost $name: the loss was reported $said times"; fail=1; return
        fi
    else
        if [ $rc = 0 ] || ! grep -q 'writing an array in place' "$W/$name.out"; then
            echo "FAIL device-lost $name: did not stop (rc $rc): $(head -c 300 "$W/$name.out")"; fail=1; return
        fi
    fi
    echo "device-lost $name: ok ($ms ms)"
}

# Tiles on the GPU and the CPU: the lost GPU's tiles go to the CPU worker.
run tiles-cpu ok lost XC_PAR_WORKERS=vulkan,cpu XC_PAR_VULKAN_LOSE=2
# The GPU alone in the set: its tiles run on the CPU after the queue.
run tiles-gpu ok lost XC_PAR_WORKERS=vulkan XC_PAR_VULKAN_LOSE=2
# One launch: the block runs on the CPU, as do the later rounds.
run single ok lost XC_PAR=gpu XC_PAR_VULKAN_LOSE=1
# An array written in place (a large heap array on an integrated GPU that
# imports host memory): the program stops. Copied (a discrete card), the
# tiles run again.
if grep -q 'sharing simd: blocks in place' "$W/probe"; then
    run writes stop writes XC_PAR_WORKERS=vulkan,cpu XC_PAR_VULKAN_LOSE=2
    run writes-single stop writes XC_PAR=gpu XC_PAR_VULKAN_LOSE=1
else
    run writes ok writes XC_PAR_WORKERS=vulkan,cpu XC_PAR_VULKAN_LOSE=2
    run writes-single ok writes XC_PAR=gpu XC_PAR_VULKAN_LOSE=1
fi
[ $fail = 0 ] && echo "device-lost: ok"
exit $fail
