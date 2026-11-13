#!/bin/bash
# vk-float64.sh — a C block over double on Vulkan (#185). A C or C++ loop
# with an int counter compiles to the 32-bit span form, which passed the
# runtime's 64-bit-integer check, so a block over double reached a device
# without doubles (the Raspberry Pi 5's V3D) and Mesa's compiler aborted the
# program. Now a kernel whose module declares Float64 (or Int64) stays on the
# CPU on a device without it, with a reason, and runs on the GPU on one with
# it; either way the program gives clang's output. Linux with a Vulkan device
# only (each device of the host is tried in turn); skipped without clang.
#
#   bash tests/par/vk-float64.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
if [ "$(uname -s)" != Linux ]; then
    echo "--- vk-float64: skipped (Linux Vulkan only) ---"
    exit 0
fi
XC=${XC:-bin/linux/xcc-xc}
if ! clang --version > /dev/null 2>&1; then
    echo "--- vk-float64: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/d.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#define N (1 << 20)
int main(void)
    {
    double* v = malloc(N * sizeof(double));
    double start = 0.5, step = 0.25;
    for (int i = 0; i < N; i++)
        v[i] = start + step * (double)i;
    double s = 0.0;
    for (int i = 0; i < N; i += 4096)
        s += v[i];
    printf("%.2f\n", s);
    return 0;
    }
C
clang -O2 -w -o "$W/ref" "$W/d.c" || { echo "FAIL vk-float64: clang does not build the program"; exit 1; }
want=$("$W/ref")
"$XC" -q -O2 -o "$W/d" "$W/d.c" > "$W/b" 2>&1 \
    || { echo "FAIL vk-float64: does not build (exit $?)"; tail -3 "$W/b"; exit 1; }
XC_PAR=gpu XC_PAR_GPU=vulkan XC_PAR_REPORT=1 "$W/d" > "$W/o" 2>&1; rc=$?
if ! grep -q 'Vulkan device is' "$W/o"; then
    echo "--- vk-float64: skipped (no Vulkan device) ---"
    exit 0
fi
dev=$(grep -m1 'Vulkan device is' "$W/o" | sed 's/.*device is //; s/,.*//')
got=$(tail -1 "$W/o")
[ $rc = 0 ] || { echo "FAIL vk-float64: exit $rc on $dev"; tail -3 "$W/o"; fail=1; }
[ "$got" = "$want" ] || { echo "FAIL vk-float64: gives $got on $dev, clang $want"; fail=1; }
grep -q 'items on the GPU\|needs doubles, which this Vulkan device does not have' "$W/o" \
    || { echo "FAIL vk-float64: neither ran on the GPU nor said why not, on $dev"; tail -4 "$W/o"; fail=1; }
[ $fail = 0 ] && echo "--- vk-float64: passed ($dev: $(grep -q 'items on the GPU' "$W/o" && echo GPU || echo CPU, no doubles)) ---"
exit $fail
