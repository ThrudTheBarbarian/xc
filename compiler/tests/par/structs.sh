#!/bin/bash
# structs.sh — par blocks over arrays of structs whose fields are not all 4
# bytes (issue #37). tests/fixtures/par_struct_words.xc works on global and
# captured local arrays of structs with padding, a nested struct, a bool and
# 1-, 2-, 4- and 8-byte fields; it must print the same on the CPU and the GPU,
# and build without a par-gpu warning (every block has a GPU form). Where the
# GPU is Metal (macOS), the report must say each of its blocks ran there.
# Where CUDA and Vulkan are both tried, each is run on its own.
# tests/fixtures/par_struct_shared_word.xc has two work items write different
# u8 fields of one element: a kernel would write each with the rest of its
# word and lose one, so that block must stay on the CPU, say why, and give the
# CPU's answer. Both compilers' builds are checked; tests/par/c/padded.c is
# the C path's case (ccorpus.sh).
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
    S=tests/fixtures/par_struct_shared_word.xc
    swant=$(cat tests/fixtures/par_struct_shared_word.expected.out)
    "$XC" -q -O2 -H . -o "$W/w.$C" "$S" > "$W/wb.$C" 2>&1 || { echo "FAIL structs ($C): shared word: no build"; fail=1; continue; }
    grep -q "at an element another work item may write" "$W/wb.$C" \
        || { echo "FAIL structs ($C): shared word: no warning that the block stays on the CPU"; fail=1; }
    for r in cpu gpu; do
        mkdir -p "$W/sw.$r"
        XC_PAR=$r XCC_SETTINGS_DIR="$W/sw.$r" XC_PAR_REPORT=1 "$W/w.$C" > "$W/wo" 2> "$W/we"
        got=$(grep -v '^par:' "$W/wo")
        [ "$got" = "$swant" ] || { echo "FAIL structs ($C, $r): shared word: '$got', wanted '$swant'"; fail=1; }
        if cat "$W/wo" "$W/we" | grep -q 'halves: .*on the GPU'; then
            echo "FAIL structs ($C, $r): shared word: the block ran on the GPU"; fail=1
        fi
    done
done
[ $fail = 0 ] && echo "structs: ok"
exit $fail
