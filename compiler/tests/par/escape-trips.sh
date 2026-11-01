#!/bin/bash
# escape-trips.sh — a block's kernels come in two variants, plain and with
# several trips of an escape loop per exit test, and each device runs the one
# it does best (2026-11-01, gpu-kernel-variants.md).
#
# The kernel copy of a pure `while` (mandelbrot's escape test) gets a second
# form per GPU interface, its header marked ` trips=8` (XTIROptGpuEscapeTrips /
# gpuEscapeTrips, eight trips per test, frozen lanes kept by selects). The
# runtime takes the variant on the Pi 5's V3D (mandelbrot 204 -> 114 ms,
# mandel_deep 22.9 -> 11.0 s) and on NVIDIA, the plain kernel where it is
# slower (an AMD iGPU, Apple); XC_PAR_VARIANT=plain|trips forces one. Checked
# here, for tests/fixtures/par_escape_trips.xc: the two compilers' arm64 Linux
# programs are the same; that program carries the variant (it differs from
# XTGPU_ESC_TRIPS=1's, which has none) while its CPU code does not change; and
# on this machine both variants give the expected answer.
#
#   bash tests/par/escape-trips.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/par_escape_trips.xc
fail=0
"$REF" -q -O2 -A arm64-linux -H . -o "$W/r" "$F" > "$W/e" 2>&1 || { echo "FAIL escape-trips: $(basename "$REF") does not build it: $(head -c 200 "$W/e")"; exit 1; }
"$XC" -q -O2 -A arm64-linux -H . -o "$W/x" "$F" > "$W/e" 2>&1 || { echo "FAIL escape-trips: $(basename "$XC") does not build it: $(head -c 200 "$W/e")"; exit 1; }
cmp -s "$W/r" "$W/x" || { echo "FAIL escape-trips: the two compilers' programs differ"; fail=1; }
XTGPU_ESC_TRIPS=1 "$XC" -q -O2 -A arm64-linux -H . -o "$W/one" "$F" > "$W/e" 2>&1 || { echo "FAIL escape-trips: no build with XTGPU_ESC_TRIPS=1"; exit 1; }
cmp -s "$W/x" "$W/one" && { echo "FAIL escape-trips: the program carries no variant kernel"; fail=1; }
# The CPU's code is untouched: the assembly without the kernels' data is the same.
"$XC" -q -O2 -A arm64-linux -H . -S -o "$W/x.s" "$F" > /dev/null 2>&1
XTGPU_ESC_TRIPS=1 "$XC" -q -O2 -A arm64-linux -H . -S -o "$W/one.s" "$F" > /dev/null 2>&1
grep -v -E '\.(byte|ascii|asciz|quad|long|short|word)\b' "$W/x.s" > "$W/x.code"
grep -v -E '\.(byte|ascii|asciz|quad|long|short|word)\b' "$W/one.s" > "$W/one.code"
cmp -s "$W/x.code" "$W/one.code" || { echo "FAIL escape-trips: the CPU code changed with the variant"; fail=1; }
"$XC" -q -O2 -H . -o "$W/host" "$F" > "$W/e" 2>&1 || { echo "FAIL escape-trips: no host build: $(head -c 200 "$W/e")"; exit 1; }
want=$(cat tests/fixtures/par_escape_trips.expected.out)
for v in plain trips; do
    mkdir -p "$W/st-$v"
    got=$(XCC_SETTINGS_DIR="$W/st-$v" XC_PAR_VARIANT=$v "$W/host" 2>/dev/null)
    [ "$got" = "$want" ] || { echo "FAIL escape-trips: XC_PAR_VARIANT=$v prints '$got'"; fail=1; }
done
[ $fail = 0 ] && echo "escape-trips: ok"
exit $fail
