#!/bin/bash
# heap-structs.sh — par blocks over heap arrays of structs (issue #113).
# tests/fixtures/par_heap_structs.xc has two `new P[n]` arrays of 64 KB and
# more, one of a struct with fields of 1, 2 and 4 bytes and padding, and one
# under 64 KB. The struct allocators page-align and register the large ones,
# so their blocks are sized at run time and have a GPU form; the small one
# stays on the CPU. Every run prints the same: the CPU, the GPU, and on Linux
# CUDA and Vulkan each on its own. Where the GPU is Metal (macOS) the report
# must show the two large blocks there. Both compilers' builds are checked.
#
#   bash tests/par/heap-structs.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/par_heap_structs.xc
want=$(cat tests/fixtures/par_heap_structs.expected.out)
fail=0
for C in xcc-xc xcc; do
    XC=bin/$PLAT/$C
    [ -x "$XC" ] || continue
    "$XC" -q -O2 -H . -o "$W/h.$C" "$F" > "$W/b.$C" 2>&1 || { echo "FAIL heap-structs ($C): no build: $(head -c 300 "$W/b.$C")"; fail=1; continue; }
    runs="cpu gpu"
    [ "$PLAT" = linux ] && runs="cpu gpu cuda vulkan"
    for r in $runs; do
        case $r in
            cuda|vulkan) env="XC_PAR=gpu XC_PAR_GPU=$r" ;;
            *) env="XC_PAR=$r" ;;
        esac
        mkdir -p "$W/st.$r"
        env $env XCC_SETTINGS_DIR="$W/st.$r" XC_PAR_REPORT=1 "$W/h.$C" > "$W/o" 2> "$W/e"
        got=$(grep -v '^par:' "$W/o")
        [ "$got" = "$want" ] || { echo "FAIL heap-structs ($C, $r): '$got', wanted '$want'"; fail=1; }
        if [ "$PLAT" = osx ] && [ "$r" = gpu ]; then
            for blk in bodies points; do
                cat "$W/o" "$W/e" | grep -q "^par: $blk: .*items on the GPU" \
                    || { echo "FAIL heap-structs ($C): block $blk did not run on the GPU"; cat "$W/o" "$W/e" | grep '^par:' | head -8; fail=1; }
            done
        fi
    done
done
[ $fail = 0 ] && echo "heap-structs: ok"
exit $fail
