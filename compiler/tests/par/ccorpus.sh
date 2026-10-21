#!/bin/bash
# ccorpus.sh — the C path's corpus: PolyBench-style kernels in tests/par/c/,
# each built by clang -O2 alone and by xcc --par-auto (the IR outliner makes
# par blocks of its loops). Each xcc build gives clang's output on the
# CPU and the GPU (Metal, or Vulkan on Linux), and makes at least as many blocks as
# tests/par/c/blocks.txt lists for it (a loop that stops being a block is a
# regression; more is progress: raise the number). Skipped where there is
# no clang. Self-hosted compiler only.
#
#   bash tests/par/ccorpus.sh [pattern]
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version >/dev/null 2>&1; then
    echo "--- ccorpus: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0; total=0
for f in tests/par/c/${1:-}*.c; do
    b=$(basename "$f" .c)
    want=$(awk -v n="$b" '$1 == n { print $2 }' tests/par/c/blocks.txt)
    # An optional third column: at most this many of its blocks may have no GPU
    # form (structs: 0, since a struct of mixed 4-byte numbers is words).
    nogpu=$(awk -v n="$b" '$1 == n { print $3 }' tests/par/c/blocks.txt)
    clang -O2 -w -o "$W/$b.ref" "$f" || { echo "FAIL ccorpus: $b: clang does not build it"; fail=1; continue; }
    ref=$("$W/$b.ref")
    XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 --par-auto -H . -o "$W/$b" "$f" > "$W/$b.log" 2>&1 \
        || { echo "FAIL ccorpus: $b does not build"; sed -n 1,5p "$W/$b.log"; fail=1; continue; }
    n=$(grep -v 'support/' "$W/$b.log" | grep -c 'outlined, a block')
    if [ -n "$nogpu" ]; then
        ng=$(grep -v 'support/' "$W/$b.log" | grep -c 'no GPU form')
        [ "$ng" -le "$nogpu" ] || { echo "FAIL ccorpus: $b: $ng blocks with no GPU form, at most $nogpu"; grep 'no GPU form' "$W/$b.log" | head -3; fail=1; }
    fi
    total=$((total + n))
    # The GPU everywhere: Metal, Vulkan (a dynamically linked program; the
    # Linux host's iGPU), else the run falls back to the CPU with the answer.
    runs="auto cpu gpu"
    bad=""
    for r in $runs; do
        if [ "$r" = auto ]; then out=$(timeout 120 "$W/$b" 2>/dev/null)
        else out=$(XC_PAR=$r timeout 120 "$W/$b" 2>/dev/null | grep -v '^par:'); fi
        [ "$out" = "$ref" ] || bad="$bad $r(got '$out', clang '$ref')"
    done
    [ -z "$bad" ] || { echo "FAIL ccorpus: $b:$bad"; fail=1; }
    if [ -z "$want" ]; then echo "FAIL ccorpus: $b has no line in blocks.txt ($n blocks)"; fail=1
    elif [ "$n" -lt "$want" ]; then echo "FAIL ccorpus: $b: $n blocks, $want before"; fail=1
    elif [ "$n" -gt "$want" ]; then echo "  $b: $n blocks, $want listed (raise it)"; fi
done
[ $fail = 0 ] && echo "--- ccorpus: pass ($total blocks) ---" || echo "--- ccorpus: FAIL ---"
[ $fail = 0 ]
