#!/bin/bash
# cuda-park.sh — CUDA keeps each block's arrays resident across blocks
# (2026-10-24): residency belonged to a parameter slot, so two blocks run in
# turn evicted each other's copies and uploaded them every time (16 MB pairs
# 2.8 ms; 0.14 ms parked). A slot about to take another block parks its copy;
# an upload of a parked block, unwritten since, takes it back; one the host
# wrote goes up again. Runs tests/fixtures/par_alternate_blocks.xc on the
# Windows host's CUDA device (XTC_WIN64_HOST, as cwin64.sh) and on a Linux
# host's (XTC_LINUX_CUDA_HOST, 2026-10-28); skipped without either.
#
#   [XTC_WIN64_HOST=<host>] [XTC_LINUX_CUDA_HOST=<host>] bash tests/par/cuda-park.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
WH=${XTC_WIN64_HOST:-}
LH=${XTC_LINUX_CUDA_HOST:-}
[ -n "$WH" ] || [ -n "$LH" ] || { echo "cuda-park: no XTC_WIN64_HOST or XTC_LINUX_CUDA_HOST, skipped"; exit 0; }
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
SSHO="-o BatchMode=yes -o LogLevel=ERROR"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
ran=""
check() {  # label, output file, 1 when the host has an NVIDIA card (CUDA must be found)
    if ! grep -q 'par: CUDA device' "$2"; then
        [ "${3:-0}" = 1 ] && { echo "FAIL cuda-park ($1): the host has an NVIDIA card but the program found no CUDA device"; fail=1; return; }
        echo "cuda-park: no CUDA device on $1, skipped there"; return
    fi
    grep -q '^runs 6, wrong 0$' "$2" || { echo "FAIL cuda-park ($1): wrong answers:"; tail -2 "$2"; fail=1; }
    grep -q 'already on the GPU (parked)' "$2" || { echo "FAIL cuda-park ($1): no block found its array parked"; fail=1; }
    ran="$ran $1"
}
if [ -n "$WH" ]; then
    "$XC" -q -A win64 -O2 -H . -o "$W/pab.exe" tests/fixtures/par_alternate_blocks.xc || { echo "FAIL cuda-park: build"; exit 1; }
    scp $SSHO -q "$W/pab.exe" "$WH:cuda-park.exe" || { echo "FAIL cuda-park: copy"; exit 1; }
    ssh $SSHO "$WH" '$env:XC_PAR="gpu"; $env:XC_PAR_REPORT="1"; .\cuda-park.exe 2>&1; Remove-Item cuda-park.exe' \
        | tr -d '\r' > "$W/out" 2>&1
    check "$WH" "$W/out"
fi
if [ -n "$LH" ]; then
    "$XC" -q -A x86_64 -O2 -H . -o "$W/pab" tests/fixtures/par_alternate_blocks.xc || { echo "FAIL cuda-park: x86-64 build"; exit 1; }
    scp $SSHO -q "$W/pab" "$LH:cuda-park.bin" || { echo "FAIL cuda-park: copy to $LH"; exit 1; }
    ssh $SSHO "$LH" 'XC_PAR=gpu XC_PAR_REPORT=1 ./cuda-park.bin 2>&1; rm -f cuda-park.bin' > "$W/lout" 2>&1
    nv=0; ssh $SSHO "$LH" 'nvidia-smi -L' 2>/dev/null | grep -q '^GPU ' && nv=1
    check "$LH" "$W/lout" $nv
fi
[ $fail = 0 ] && echo "cuda-park: ok (${ran# })"
exit $fail
