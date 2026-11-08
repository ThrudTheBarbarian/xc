#!/bin/bash
# variant-keep.sh — auto times both of a block's GPU kernels and keeps one
# (#6, 2026-11-07).
#
# A block whose escape loop has a trips=<n> variant carries two kernels. auto
# used a fixed rule per device (the variant on the V3D and NVIDIA, the plain
# kernel elsewhere), which was right only where it was measured: on an M3 Max
# the variant is 0.81x on mandelbrot and 1.13x on mandel_deep. Now auto times
# both while it measures the GPU, keeps the faster in the program's settings
# (par.variant.<hw>.<block>.<code>), and a later run uses it without timing
# again. Where the program can reach the GPU through CUDA and Vulkan (x86-64
# Linux and Windows), auto keeps the interface first and times the kernels on
# it. Where the host has no GPU, or the block carries one kernel, there is
# nothing to check.
#
#   bash tests/par/variant-keep.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
"$XC" -q -H . -O3 -o "$W/m" ../benchmark/par/mandelbrot.xc > "$W/build" 2>&1 || { echo "FAIL variant-keep: build"; head -3 "$W/build"; exit 1; }
export XCC_SETTINGS_DIR="$W/st"; mkdir -p "$XCC_SETTINGS_DIR"
XC_PAR_REPORT=1 "$W/m" > "$W/r1" 2>&1
if ! grep -q "hardware key" "$W/r1" || grep -q "hardware key [0-9a-f]* (|" "$W/r1"; then
    echo "SKIP variant-keep: no GPU on this host"; exit 0
fi
grep -q "auto times the .* kernel next" "$W/r1" || { echo "SKIP variant-keep: the block carries one kernel here"; exit 0; }
fail=0
grep -q "auto keeps the \(plain\|trips\) kernel" "$W/r1" || { echo "FAIL variant-keep: both kernels timed, none kept"; grep par: "$W/r1" | head -5; fail=1; }
kept=$(grep -h "^par\.variant\..* = " "$W"/st/*.conf 2>/dev/null | head -1 | sed 's/.* = //')
case "$kept" in plain|trips) ;; *) echo "FAIL variant-keep: the settings keep '$kept'"; fail=1 ;; esac
XC_PAR_REPORT=1 "$W/m" > "$W/r2" 2>&1
grep -q "auto times the .* kernel next\|auto keeps the" "$W/r2" && { echo "FAIL variant-keep: the second run timed the kernels again"; fail=1; }
[ "$(tail -1 "$W/r2" | awk '{print $1}')" = "$(tail -1 "$W/r1" | awk '{print $1}')" ] || { echo "FAIL variant-keep: the checksum changed"; fail=1; }
[ $fail = 0 ] && echo "variant-keep: ok (kept $kept)"
exit $fail
