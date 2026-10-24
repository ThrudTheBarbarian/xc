#!/bin/bash
# cuda-park.sh — CUDA keeps each block's arrays resident across blocks
# (2026-10-24): residency belonged to a parameter slot, so two blocks run in
# turn evicted each other's copies and uploaded them every time (16 MB pairs
# 2.8 ms; 0.14 ms parked). A slot about to take another block parks its copy;
# an upload of a parked block, unwritten since, takes it back; one the host
# wrote goes up again. Runs tests/fixtures/par_alternate_blocks.xc on the
# Windows host's CUDA device (XTC_WIN64_HOST, as cwin64.sh); skipped without
# one.
#
#   XTC_WIN64_HOST=<host> bash tests/par/cuda-park.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
WH=${XTC_WIN64_HOST:-}
[ -n "$WH" ] || { echo "cuda-park: no XTC_WIN64_HOST, skipped"; exit 0; }
XC=${XC:-bin/osx/xcc-xc}
SSHO="-o BatchMode=yes -o LogLevel=ERROR"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
"$XC" -q -A win64 -O2 -H . -o "$W/pab.exe" tests/fixtures/par_alternate_blocks.xc || { echo "FAIL cuda-park: build"; exit 1; }
scp $SSHO -q "$W/pab.exe" "$WH:cuda-park.exe" || { echo "FAIL cuda-park: copy"; exit 1; }
ssh $SSHO "$WH" '$env:XC_PAR="gpu"; $env:XC_PAR_REPORT="1"; .\cuda-park.exe 2>&1; Remove-Item cuda-park.exe' \
    | tr -d '\r' > "$W/out" 2>&1
grep -q 'par: CUDA device' "$W/out" || { echo "cuda-park: no CUDA device on $WH, skipped"; exit 0; }
fail=0
grep -q '^runs 6, wrong 0$' "$W/out" || { echo "FAIL cuda-park: wrong answers:"; tail -2 "$W/out"; fail=1; }
grep -q 'already on the GPU (parked)' "$W/out" || { echo "FAIL cuda-park: no block found its array parked"; fail=1; }
[ $fail = 0 ] && echo "cuda-park: ok"
exit $fail
