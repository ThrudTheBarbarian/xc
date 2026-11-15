#!/bin/bash
# arrayreduce-gpu.sh — an array reduction over 32-bit integers runs on Metal
# (#143). par_array_reduce_gpu's blocks (a threadgroup copy of the array, and
# atomics on the array itself) and the u32 block of par_array_reduce must
# report their items on the GPU under XC_PAR=gpu; the u8, u16 and u64 blocks
# stay on the CPU. Every run prints the expected output: the atomics race
# only now and then, so each program runs RUNS times (default 20), under
# XC_PAR=gpu and under the default auto. A block never runs as tiles split
# between devices. macOS on Apple silicon only; elsewhere it says so and
# passes.
#
#   bash tests/par/arrayreduce-gpu.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 2
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "arrayreduce-gpu: not macOS on Apple silicon, nothing to check"
    exit 0
fi
XCC=${XCC:-bin/osx/xcc-xc}
RUNS=${RUNS:-20}
[ -x "$XCC" ] || { echo "arrayreduce-gpu: no compiler at $XCC"; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/par-arrgpu.XXXXXX")
trap 'rm -rf "${W:?}"' EXIT
fail=0
for name in par_array_reduce_gpu par_array_reduce par_auto_array_reduce; do
    if ! "$XCC" -q -H . -o "$W/$name" "tests/fixtures/$name.xc" > "$W/$name.err" 2>&1; then
        echo "FAIL $name: does not build"; head -5 "$W/$name.err"; fail=1; continue
    fi
    exp="tests/fixtures/$name.expected.out"
    mkdir -p "$W/st-$name"
    for mode in gpu auto; do
        for r in $(seq 1 "$RUNS"); do
            if ! XCC_SETTINGS_DIR="$W/st-$name" XC_PAR=$mode XC_PAR_REPORT=1 timeout 60 "$W/$name" > "$W/all" 2>&1; then
                echo "FAIL $name with XC_PAR=$mode, run $r: it failed"; head -5 "$W/all"; fail=1; break
            fi
            grep '^par:' "$W/all" > "$W/rep"
            if ! grep -v '^par:' "$W/all" | cmp -s - "$exp"; then
                echo "FAIL $name with XC_PAR=$mode, run $r:"; grep -v '^par:' "$W/all" | diff - "$exp" | head -5; fail=1; break
            fi
            if grep -q 'items on the GPU in [0-9]* tiles' "$W/rep"; then
                echo "FAIL $name with XC_PAR=$mode: a block ran as tiles"; fail=1; break
            fi
            [ "$mode" = gpu ] && [ "$r" = 1 ] && cp "$W/rep" "$W/$name.rep"
        done
    done
done
# Where each block ran, from the first XC_PAR=gpu run's report.
for b in hist256 hist64k orbits andbits andwide xorbits negs both; do
    grep -q "par: $b: [0-9]* items on the GPU" "$W/par_array_reduce_gpu.rep" 2>/dev/null ||
        { echo "FAIL par_array_reduce_gpu: block $b did not run on the GPU"; fail=1; }
done
grep -q "par: count: [0-9]* items on the GPU" "$W/par_array_reduce.rep" 2>/dev/null ||
    { echo "FAIL par_array_reduce: the u32 block did not run on the GPU"; fail=1; }
n=$(grep -c 'stays on the CPU: it has no Metal version' "$W/par_array_reduce.rep" 2>/dev/null)
[ "${n:-0}" -ge 3 ] || { echo "FAIL par_array_reduce: ${n:-0} blocks stayed on the CPU, want at least the u8, u16 and u64 ones"; fail=1; }
# The lifted loops into hist (u32 +=) and into mask and mix (&= and ^=).
for at in 33 103; do
    grep -q "par: par_auto_array_reduce.xc:$at: [0-9]* items on the GPU" "$W/par_auto_array_reduce.rep" 2>/dev/null ||
        { echo "FAIL par_auto_array_reduce: the loop at line $at did not run on the GPU"; fail=1; }
done
# The compiler names why the narrow and wide arrays stay on the CPU.
for w in 8 16 64; do
    grep -q "over $w-bit integers, and its GPU version takes 32-bit ones" "$W/par_array_reduce.err" ||
        { echo "FAIL par_array_reduce: no warning for the $w-bit array"; fail=1; }
done
[ $fail = 0 ] && echo "arrayreduce-gpu: ok"
exit $fail
