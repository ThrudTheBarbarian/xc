#!/bin/bash
# gpu-reasons.sh — XC_PAR_REPORT says a block stays on the CPU only when it
# does (2026-11-01). Where CUDA and Vulkan are both tried (x86-64 glibc Linux,
# Windows), a host without CUDA used to report "a block stays on the CPU:
# there is no CUDA device" and then run the block on the GPU through Vulkan;
# the reasons are now held until no interface takes the block. Checked here:
# a block on this host's GPU carries no such line, and a block every interface
# refuses (Vulkan pointed at a driver that does not exist) says why, once per
# interface. On a host whose GPU is not reached that way the first check has
# nothing to look at, and on one with CUDA the second block runs on it.
#
#   bash tests/par/gpu-reasons.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/fill.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
    {
    u32 n = (u32)1048576;
    float* a = new float[n];
    par fill :device(gpu)
        {
        for (u32 i in 0..n)
            a[i] = (float)i * 0.5f;
        }
    Stdio.printf("%.1f\n", (double)a[n - (u32)1]);
    return (i32)0;
    }
XC
"$XC" -q -O2 -o "$W/fill" "$W/fill.xc" > "$W/e" 2>&1 || { echo "FAIL gpu-reasons: no build: $(head -c 200 "$W/e")"; exit 1; }
mkdir -p "$W/st"
XCC_SETTINGS_DIR="$W/st" XC_PAR_REPORT=1 "$W/fill" > "$W/out" 2>&1
grep -qx '524287.5' "$W/out" || { echo "FAIL gpu-reasons: wrong answer: $(head -c 200 "$W/out")"; fail=1; }
if grep -q 'items on the GPU' "$W/out" && grep -q 'stays on the CPU' "$W/out"; then
    echo "FAIL gpu-reasons: a block the GPU ran was reported as staying on the CPU:"; grep 'stays on the CPU' "$W/out"; fail=1
fi
# Every interface refuses: Vulkan has no driver to load (and, on a host
# without CUDA, CUDA has no device).
XCC_SETTINGS_DIR="$W/st" XC_PAR_REPORT=1 VK_ICD_FILENAMES=/nonexistent.json VK_DRIVER_FILES=/nonexistent.json \
    "$W/fill" > "$W/cpu" 2>&1
grep -qx '524287.5' "$W/cpu" || { echo "FAIL gpu-reasons: wrong answer with no GPU: $(head -c 200 "$W/cpu")"; fail=1; }
if grep -q 'items on the CPU' "$W/cpu" && ! grep -q 'stays on the CPU: ' "$W/cpu"; then
    echo "FAIL gpu-reasons: a block on the CPU did not say why:"; head -5 "$W/cpu"; fail=1
fi
[ $fail = 0 ] && echo "gpu-reasons: ok"
exit $fail
