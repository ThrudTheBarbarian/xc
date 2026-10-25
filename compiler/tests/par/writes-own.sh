#!/bin/bash
# writes-own.sh — a captured array the block overwrites whole is not sent to
# the device (2026-10-25). Globals had gpuWritesAll; a captured array (or a
# pointer to one) was uploaded even when the body only wrote it. Now the
# block reports gpuWritesAllOwn(k) for the shape that cannot miss an element
# (a top-level `a[i] = e;` on the loop variable, a named nowhere else, no
# early exit), the runtime checks the run covers the whole array, and CUDA
# allocates it without the copy, Metal makes an empty buffer, Vulkan skips
# the copy into its mapping. tests/fixtures/par_writes_own.xc: one block
# overwrites ys (reported), one writes half of zs (whose other half must
# survive), one reads acc as it writes it. The CUDA run of that block, on an
# RTX 5080: 7.2 -> 3.6 ms; Vulkan 10.4 -> 9.5.
# Here: the CPU answer, and on a Mac the Metal one with its report; on the
# Windows host (XTC_WIN64_HOST) CUDA and Vulkan with theirs.
#
#   [XTC_WIN64_HOST=<host>] bash tests/par/writes-own.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
F=tests/fixtures/par_writes_own.xc
WANT=$(cat tests/fixtures/par_writes_own.expected.out)
"$XC" -q -O2 -H . -o "$W/p" "$F" > "$W/b" 2>&1 || { echo "FAIL writes-own: does not build"; head -3 "$W/b"; exit 1; }
got=$(XC_PAR=cpu "$W/p" 2>/dev/null)
[ "$got" = "$WANT" ] || { echo "FAIL writes-own: CPU gives '$got'"; fail=1; }
check() {   # $1: label, $2: the run's output
    local out="$2"
    echo "$out" | grep -q 'items on the GPU' || { echo "writes-own: no $1 GPU, skipped"; return; }
    [ "$(echo "$out" | grep -c 'written whole on the device, not sent')" = 1 ] \
        || { echo "FAIL writes-own: $1 reports $(echo "$out" | grep -c 'written whole') arrays written whole, want 1"; fail=1; }
    echo "$out" | grep -q '16777216 bytes written whole' || { echo "FAIL writes-own: $1 did not take ys whole"; fail=1; }
    [ "$(echo "$out" | grep -E '^[0-9]' | tail -1)" = "$WANT" ] \
        || { echo "FAIL writes-own: $1 gives '$(echo "$out" | grep -E '^[0-9]' | tail -1)'"; fail=1; }
}
if [ "$(uname -s)" = Darwin ]; then
    check Metal "$(XC_PAR=gpu XC_PAR_REPORT=1 "$W/p" 2>&1)"
fi
WH=${XTC_WIN64_HOST:-}
if [ -n "$WH" ]; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    "$XC" -q -A win64 -O2 -H . -o "$W/p.exe" "$F" || { echo "FAIL writes-own: no win64 build"; exit 1; }
    if scp $SSHO -q "$W/p.exe" "$WH:writes-own.exe"; then
        for g in cuda vulkan; do
            out=$(ssh $SSHO "$WH" "\$env:XC_PAR=\"gpu\"; \$env:XC_PAR_REPORT=\"1\"; \$env:XC_PAR_GPU=\"$g\"; .\\writes-own.exe 2>&1" | tr -d '\r')
            check "$g" "$out"
        done
        ssh $SSHO "$WH" 'Remove-Item writes-own.exe' > /dev/null 2>&1
    fi
fi
[ $fail = 0 ] && echo "writes-own: ok"
exit $fail
