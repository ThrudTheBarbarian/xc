#!/bin/bash
# slices.sh — slices of one big array written through `stack + k*n` by one
# block, then the whole array read by another (2026-10-26, reported by the
# Astronomancy stream). A write through a pointer INTO a block did not move
# the block's generation, so CUDA took its kept copy of the whole array for
# current and the combine saw only the first slice (99.9 for 1003.5). Here the
# CPU's answer and this machine's GPU's; on the Windows host (XTC_WIN64_HOST,
# as cuda-park.sh) and on a Linux host with an NVIDIA card (XTC_LINUX_CUDA_HOST)
# CUDA's, forced with XC_PAR=gpu.
#
#   [XTC_WIN64_HOST=<host>] [XTC_LINUX_CUDA_HOST=<host>] bash tests/par/slices.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
F=tests/fixtures/par_slices.xc
WANT=$(cat tests/fixtures/par_slices.expected.out)
"$XC" -q -O2 -H . -o "$W/p" "$F" || { echo "FAIL slices: does not build"; exit 1; }
for m in cpu gpu; do
    got=$(XC_PAR=$m XCC_SETTINGS_DIR="$W/s-$m" "$W/p" 2>/dev/null)
    [ "$got" = "$WANT" ] || { echo "FAIL slices: XC_PAR=$m gives '$got'"; fail=1; }
done
WH=${XTC_WIN64_HOST:-}
if [ -n "$WH" ]; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    "$XC" -q -A win64 -O2 -H . -o "$W/p.exe" "$F" || { echo "FAIL slices: win64 build"; exit 1; }
    scp $SSHO -q "$W/p.exe" "$WH:slices.exe" || { echo "FAIL slices: copy"; exit 1; }
    ssh $SSHO "$WH" '$env:XC_PAR="gpu"; $env:XC_PAR_REPORT="1"; .\slices.exe 2>&1; Remove-Item slices.exe' \
        | tr -d '\r' > "$W/out" 2>&1
    if grep -q 'par: CUDA device' "$W/out"; then
        got=$(grep -E '^[0-9.]+ [0-9.]+$' "$W/out" | tail -1)
        [ "$got" = "$WANT" ] || { echo "FAIL slices: CUDA gives '$got'"; fail=1; }
    else
        echo "slices: no CUDA device on $WH, CUDA not checked"
    fi
fi
LH=${XTC_LINUX_CUDA_HOST:-}
if [ -n "$LH" ]; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    "$XC" -q -A x86_64 -O2 -H . -o "$W/p.lx" "$F" || { echo "FAIL slices: x86-64 build"; exit 1; }
    scp $SSHO -q "$W/p.lx" "$LH:slices.bin" || { echo "FAIL slices: copy to $LH"; exit 1; }
    ssh $SSHO "$LH" 'XC_PAR=gpu XC_PAR_REPORT=1 ./slices.bin 2>&1; rm -f slices.bin' > "$W/lout" 2>&1
    if grep -q 'par: CUDA device' "$W/lout"; then
        got=$(grep -E '^[0-9.]+ [0-9.]+$' "$W/lout" | tail -1)
        [ "$got" = "$WANT" ] || { echo "FAIL slices: CUDA on Linux gives '$got'"; fail=1; }
    elif ssh $SSHO "$LH" 'nvidia-smi -L' 2>/dev/null | grep -q '^GPU '; then
        echo "FAIL slices: $LH has an NVIDIA card but the program found no CUDA device"; fail=1
    else
        echo "slices: no CUDA device on $LH, Linux CUDA not checked"
    fi
fi
[ $fail = 0 ] && echo "slices: ok"
exit $fail
