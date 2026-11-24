#!/bin/bash
# vulkan-inputs.sh — a single-shot Vulkan run does not send an input again
# while the host leaves it alone (#15). par_vulkan_inputs runs a block ten
# times over a 16 MB table it only reads: with no host access between runs
# the table goes up once (nine runs find it "already on the GPU, unchanged
# since"); with a host write to it between runs it goes up every time. Both
# print what the CPU prints. A device that shares the arrays in place sends
# nothing either way. Skipped where there is no Vulkan device.
#
#   bash tests/par/vulkan-inputs.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
[ "$PLAT" = osx ] && { echo "--- vulkan-inputs: skipped (no Vulkan on macOS) ---"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
"$XC" -q -O2 -H . -o "$W/v" tests/fixtures/par_vulkan_inputs.xc > "$W/b" 2>&1 || { echo "FAIL vulkan-inputs: no build: $(head -c 300 "$W/b")"; exit 1; }
run() { (cd "$W" && env $1 ./v $2); }
dev=$(run "XC_PAR=gpu XC_PAR_GPU=vulkan XC_PAR_TILES=0 XC_PAR_REPORT=1" "" 2>&1 | grep "Vulkan device is")
[ -n "$dev" ] || { echo "--- vulkan-inputs: skipped (no Vulkan device) ---"; exit 0; }
# A device that shares the program's arrays in place (an integrated GPU that
# imports host memory) copies nothing, so there is nothing to keep.
shared=0
case "$dev" in *"sharing simd: blocks in place"*) shared=1 ;; esac
for args in "" "x"; do
    want=$(run "XC_PAR=cpu" "$args" 2>/dev/null)
    out=$(run "XC_PAR=gpu XC_PAR_GPU=vulkan XC_PAR_TILES=0 XC_PAR_REPORT=1" "$args" 2>&1)
    got=$(echo "$out" | grep -v '^par:')
    [ "$got" = "$want" ] || { echo "  FAIL: args '$args': '$got', wanted '$want'"; fail=1; }
    kept=$(echo "$out" | grep -c 'already on the GPU, unchanged since')
    case "$args" in "") wk=9 ;; *) wk=0 ;; esac
    [ $shared = 1 ] && wk=0
    [ "$kept" = "$wk" ] || { echo "  FAIL: args '$args': the table was found unchanged $kept times, wanted $wk"; fail=1; }
done
[ $fail = 0 ] && echo "--- vulkan-inputs: pass ---" || { echo "--- vulkan-inputs: FAIL ---"; exit 1; }
