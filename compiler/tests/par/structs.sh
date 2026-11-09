#!/bin/bash
# structs.sh — par blocks over arrays of structs whose fields are not all 4
# bytes (issue #37). tests/fixtures/par_struct_words.xc works on global and
# captured local arrays of structs with padding, a nested struct, a bool and
# 1-, 2-, 4- and 8-byte fields; it must print the same on the CPU and the GPU,
# and build without a par-gpu warning (every block has a GPU form). Where the
# GPU is Metal (macOS), the report must say each of its blocks ran there.
# Where CUDA and Vulkan are both tried, each is run on its own. Both
# compilers' builds are checked; tests/par/c/padded.c is the C path's case
# (ccorpus.sh).
#
#   bash tests/par/structs.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/par_struct_words.xc
want=$(cat tests/fixtures/par_struct_words.expected.out)
fail=0
for C in xcc-xc xcc; do
    XC=bin/$PLAT/$C
    [ -x "$XC" ] || continue
    "$XC" -q -O2 -H . -o "$W/s.$C" "$F" > "$W/b.$C" 2>&1 || { echo "FAIL structs ($C): no build: $(head -c 300 "$W/b.$C")"; fail=1; continue; }
    if grep -q "runs on the CPU only" "$W/b.$C"; then
        echo "FAIL structs ($C): a block has no GPU form:"; grep -A1 "runs on the CPU only" "$W/b.$C" | head -4; fail=1
    fi
    runs="cpu gpu"
    [ "$PLAT" = linux ] && runs="cpu gpu cuda vulkan"
    for r in $runs; do
        case $r in
            cuda|vulkan) env="XC_PAR=gpu XC_PAR_GPU=$r" ;;
            *) env="XC_PAR=$r" ;;
        esac
        mkdir -p "$W/st.$r"
        env $env XCC_SETTINGS_DIR="$W/st.$r" XC_PAR_REPORT=1 "$W/s.$C" > "$W/o" 2> "$W/e"
        got=$(grep -v '^par:' "$W/o")
        [ "$got" = "$want" ] || { echo "FAIL structs ($C, $r): '$got', wanted '$want'"; fail=1; }
        if [ "$PLAT" = osx ] && [ "$r" = gpu ]; then
            n=$(cat "$W/o" "$W/e" | grep -c 'items on the GPU')
            [ "$n" -ge 5 ] || { echo "FAIL structs ($C): $n blocks on the GPU, wanted 5"; cat "$W/o" "$W/e" | grep '^par:' | head -8; fail=1; }
        fi
    done
done
[ $fail = 0 ] && echo "structs: ok"
exit $fail
