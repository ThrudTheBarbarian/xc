#!/bin/bash
# par-gpu-declines.sh — where the GPU cannot run a block (a Raspberry Pi 5's
# V3D, and a GPU version that needs 64-bit integers), auto leaves the GPU out
# of its comparison and goes on measuring: it picks the CPU on one thread for
# saxpy, which is bound by memory, and the tile queue's Vulkan worker declines
# the block instead of handing V3D a kernel Mesa aborts on. Run on an arm64
# Linux machine whose Vulkan device lacks 64-bit integers; skipped elsewhere.
# Self-hosted compiler only (the C path).
#
#   bash tests/driver/par-gpu-declines.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
XC=${XC:-bin/$PLAT/xcc-xc}
case "$(uname -s)-$(uname -m)" in
    Linux-aarch64|Linux-arm64) ;;
    *) echo "par-gpu-declines: not an arm64 Linux machine, skipped"; exit 0 ;;
esac
W=$(mktemp -d /tmp/gpudecl.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0
"$XC" -q -O3 --par-style=auto -I ../benchmark/par/c -o "$W/s" ../benchmark/par/c/saxpy.c 2> "$W/err" || { echo "FAIL build"; head -3 "$W/err"; exit 1; }
XCC_SETTINGS_DIR="$W/st" XC_PAR_REPORT=1 "$W/s" > "$W/a.out" 2>&1 || { echo "FAIL the measuring run failed"; tail -5 "$W/a.out"; fail=1; }
if ! grep -q '64-bit integers, which this Vulkan device does not have' "$W/a.out"; then
    echo "par-gpu-declines: this machine's GPU runs the block, skipped"; exit 0
fi
grep -q 'saxpy.c:24: auto leaves the GPU out' "$W/a.out" || { echo "FAIL auto did not leave the GPU out"; grep 'saxpy.c:24' "$W/a.out" | head -5; fail=1; }
grep -q 'saxpy.c:24: auto picks the CPU on one thread' "$W/a.out" || { echo "FAIL auto did not finish measuring on one thread"; grep 'saxpy.c:24' "$W/a.out" | tail -5; fail=1; }
# The learned choice, in later processes: no Mesa abort, the same answer.
for k in 1 2; do
    XCC_SETTINGS_DIR="$W/st" "$W/s" > "$W/b.out" 2>&1 || { echo "FAIL a later run failed"; tail -3 "$W/b.out"; fail=1; break; }
    [ "$(tail -1 "$W/b.out" | cut -d' ' -f1)" = "$(tail -1 "$W/a.out" | cut -d' ' -f1)" ] || { echo "FAIL a later run's checksum differs"; fail=1; }
done
[ $fail = 0 ] && echo "par-gpu-declines: ok"
exit $fail
