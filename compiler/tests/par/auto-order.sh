#!/bin/bash
# auto-order.sh — auto measures the CPU before "all devices" (2026-10-30).
#
# The tile queue seeds each worker's rate from auto's measurements, and an
# unmeasured CPU pool beside a GPU is taken as a hundred times slower and given
# no tile. Auto measured the all-devices set before the CPU, so the CPU had no
# rate there: on a Raspberry Pi 5 the four cores (14.0 s for mandel_deep) took
# none of the tiles and "all devices" came out as the V3D alone (19.2 s, where
# with the CPU's rate it is 9.5 s). Here a compute-bound block is run until
# auto decides, and its report must time the CPU before the first
# all-devices run. Nothing to check where the host has no GPU worker for the
# tile queue (auto then never tries all devices). With XTC_LINUX_ARM64_HOST
# set, the program is also built for arm64 Linux and run there (the Pi, where
# auto does try all devices).
#
#   [XTC_LINUX_ARM64_HOST=<host>] bash tests/par/auto-order.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
cat > "$W/order.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
#define W 1024
u32 counts[W * W];
i32 main(void)
    {
    for (u32 rep = (u32)0; rep < (u32)10; rep = rep + (u32)1)
        {
        // An escape loop per item: compute-bound (a loop in the body), so
        // auto tries all devices where there is a GPU worker.
        par heavy
            {
            for (u32 i in 0..(u32)(W * W))
                {
                float cx = (float)(i % (u32)W) * (1.5f / (float)W) - 1.5f;
                float cy = (float)(i / (u32)W) * (1.5f / (float)W) - 0.75f;
                float x = 0.0f;
                float y = 0.0f;
                u32 k = (u32)0;
                while (k < (u32)256 && x * x + y * y < 4.0f)
                    {
                    float xt = x * x - y * y + cx;
                    y = 2.0f * x * y + cy;
                    x = xt;
                    k = k + (u32)1;
                    }
                counts[i] = k;
                }
            }
        }
    Stdio.printf("%u\n", counts[(u32)(W * W / 2 + W / 2)]);
    return (i32)0;
    }
XC
"$XC" -q -O2 -o "$W/order" "$W/order.xc" > "$W/e" 2>&1 || { echo "FAIL auto-order: does not build: $(head -c 200 "$W/e")"; exit 1; }
# check <report>: the CPU timed before the first all-devices run.
check() {
    if ! grep -q 'us on all devices' "$1"; then
        echo "auto-order: ok on $2 (all devices not tried there)"; return 0
    fi
    cpu=$(grep -n 'items on the CPU' "$1" | head -1 | cut -d: -f1)
    all=$(grep -n 'us on all devices' "$1" | head -1 | cut -d: -f1)
    if [ -z "$cpu" ] || [ "$cpu" -gt "$all" ]; then
        echo "FAIL auto-order: on $2 all devices was measured before the CPU (CPU line ${cpu:-none}, all devices line $all)"
        return 1
    fi
    echo "auto-order: ok on $2"
}
fail=0
mkdir -p "$W/settings"
XCC_SETTINGS_DIR="$W/settings" XC_PAR=auto XC_PAR_REPORT=1 "$W/order" > "$W/r" 2>&1 \
    || { echo "FAIL auto-order: the program failed: $(tail -3 "$W/r")"; exit 1; }
check "$W/r" "this host" || fail=1
H=${XTC_LINUX_ARM64_HOST:-}
if [ -n "$H" ]; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    "$XC" -q -O2 -A arm64-linux -o "$W/order-a" "$W/order.xc" > "$W/e" 2>&1 || { echo "FAIL auto-order: no arm64 Linux build: $(head -c 200 "$W/e")"; exit 1; }
    scp $SSHO -q "$W/order-a" "$H:auto-order.bin" || { echo "FAIL: copy to the host"; exit 1; }
    ssh $SSHO "$H" 'rm -rf auto-order.st && mkdir auto-order.st && XCC_SETTINGS_DIR=auto-order.st XC_PAR=auto XC_PAR_REPORT=1 ./auto-order.bin 2>&1; rm -rf auto-order.bin auto-order.st' > "$W/ra"
    check "$W/ra" "$H" || fail=1
fi
exit $fail
