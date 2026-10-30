#!/bin/bash
# vulkan-span32.sh — par kernels for a GPU without 64-bit integers, in both
# compilers (2026-10-30)
#
# A Vulkan kernel whose only 64-bit integers are its range (the span push
# constants and the block's lo/hi, read only to be truncated) is emitted in
# the 32-bit span form: no Int64 capability, marked `span=32` in its header,
# so a device without shaderInt64 (the Raspberry Pi 5's V3D) runs it. A
# kernel whose body computes in 64 bits keeps the 64-bit form. Both compilers
# must write the same program. With XTC_LINUX_ARM64_HOST set to an arm64
# Linux machine with such a GPU, two fixtures must run on its GPU and print
# what they should: par_simd_buffers (the 32-bit form) and par_writes_own,
# whose 4M-item blocks need more than the 65535 workgroups a Vulkan device is
# guaranteed (they used to launch nothing there).
#
#   [XTC_LINUX_ARM64_HOST=<host>] bash tests/driver/vulkan-span32.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
for b in par_simd_buffers par_writes_own par_gpu_wide; do
    for s in r x; do
        c=$REF; [ $s = x ] && c=$XC
        "$c" -q -O2 -A arm64-linux -o "$W/$s-$b" "tests/fixtures/$b.xc" > "$W/e" 2>&1 \
            || { echo "FAIL vulkan-span32: $(basename "$c") does not build $b: $(head -c 200 "$W/e")"; fail=1; }
    done
    [ -f "$W/r-$b" ] && [ -f "$W/x-$b" ] && { cmp -s "$W/r-$b" "$W/x-$b" \
        || { echo "FAIL vulkan-span32: the two compilers' $b differ"; fail=1; }; }
done
[ $fail = 0 ] && {
    strings "$W/x-par_simd_buffers" | grep -q 'xcpar size=.* span=32 ' \
        || { echo "FAIL vulkan-span32: par_simd_buffers' kernel is not in the 32-bit span form"; fail=1; }
    # Workgroups of 256 (2026-10-30): the V3D ran a kernel 3x slower in 64s.
    strings "$W/x-par_simd_buffers" | grep 'xcpar size=' | grep -q ' wg=256' \
        || { echo "FAIL vulkan-span32: par_simd_buffers' kernel does not declare 256-thread workgroups"; fail=1; }
    strings "$W/x-par_gpu_wide" | grep 'xcpar size=' | grep -q 'span=32' \
        && { echo "FAIL vulkan-span32: par_gpu_wide computes in 64 bits but its kernel claims the 32-bit form"; fail=1; }
}
msg="code"
H=${XTC_LINUX_ARM64_HOST:-}
if [ $fail = 0 ] && [ -n "$H" ]; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    ssh $SSHO "$H" 'rm -rf vs32 && mkdir vs32' || { echo "FAIL: the host"; exit 1; }
    for b in par_simd_buffers par_writes_own; do
        scp $SSHO -q "$W/x-$b" "$H:vs32/$b" && scp $SSHO -q "tests/fixtures/$b.expected.out" "$H:vs32/$b.exp" \
            || { echo "FAIL: copy to the host"; exit 1; }
        out=$(ssh $SSHO "$H" "cd vs32 && XC_PAR=gpu XC_PAR_REPORT=1 ./$b > $b.out 2>&1; grep -v '^par:' $b.out | cmp -s - $b.exp && echo RIGHT; grep -c 'items on the GPU' $b.out; grep -m1 'stays on the CPU' $b.out")
        case "$out" in
            RIGHT*) n=$(echo "$out" | sed -n 2p); [ "${n:-0}" -ge 1 ] \
                || { echo "FAIL vulkan-span32: $b ran no block on the host's GPU: $(echo "$out" | sed -n 3p)"; fail=1; } ;;
            *) echo "FAIL vulkan-span32: $b is wrong on the host's GPU"; fail=1 ;;
        esac
    done
    ssh $SSHO "$H" 'rm -rf vs32'
    msg="code and run"
fi
[ $fail = 0 ] && echo "vulkan-span32: ok ($msg)"
exit $fail
