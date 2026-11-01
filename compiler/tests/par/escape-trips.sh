#!/bin/bash
# escape-trips.sh — a GPU kernel's escape loop gets several trips per exit test
# (2026-11-01), and the CPU's code does not.
#
# The kernel copy of a pure `while` (mandelbrot's escape test) runs eight trips
# per test, frozen lanes kept by selects (XTIROptGpuEscapeTrips in the
# reference, gpuEscapeTrips in the port): on the Pi 5's V3D mandelbrot went from
# 204 to 114 ms and mandel_deep from 22.9 to 11.0 s. Checked here, for
# tests/fixtures/par_escape_trips.xc built for arm64 Linux (SPIR-V) by both
# compilers: the program is the same from each; the kernel differs from the one
# XTGPU_ESC_TRIPS=1 gives (the pass ran) while the CPU code does not; and the
# program's answer on this machine is the expected one.
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
cmp -s "$W/x" "$W/one" && { echo "FAIL escape-trips: the kernel is the same with one trip per test (the pass did not run)"; fail=1; }
# The CPU's code is untouched: the assembly without the kernels is the same.
"$XC" -q -O2 -A arm64-linux -H . -S -o "$W/x.s" "$F" > /dev/null 2>&1
XTGPU_ESC_TRIPS=1 "$XC" -q -O2 -A arm64-linux -H . -S -o "$W/one.s" "$F" > /dev/null 2>&1
grep -v -E '\.(byte|ascii|asciz|quad|long|short|word)\b' "$W/x.s" > "$W/x.code"
grep -v -E '\.(byte|ascii|asciz|quad|long|short|word)\b' "$W/one.s" > "$W/one.code"
cmp -s "$W/x.code" "$W/one.code" || { echo "FAIL escape-trips: the CPU code changed with the trips"; fail=1; }
"$XC" -q -O2 -H . -o "$W/host" "$F" > "$W/e" 2>&1 || { echo "FAIL escape-trips: no host build: $(head -c 200 "$W/e")"; exit 1; }
mkdir -p "$W/st"
got=$(XCC_SETTINGS_DIR="$W/st" "$W/host" 2>/dev/null)
[ "$got" = "$(cat tests/fixtures/par_escape_trips.expected.out)" ] || { echo "FAIL escape-trips: prints '$got'"; fail=1; }
[ $fail = 0 ] && echo "escape-trips: ok"
exit $fail
