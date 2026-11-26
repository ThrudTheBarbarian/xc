#!/bin/bash
# guard-bound.sh — the overlap guard's range check for reads an inner loop
# bounds (tests/par/c-bound/bound.c): an inner counter up to a value from
# outside the loop (nbody's `j < n`), the same array read at [j] and at [i],
# a counter up to i, and one stepping by 4. Each loop is a guarded block,
# and of its three calls the block runs for the two whose ranges are apart
# (two allocations; one allocation, without overlap) and not for the
# overlapping one, which runs as written. The arrays are under 64 KB, which
# Par.spanOf cannot size on glibc, so only the range check lets the first
# two run. Every call gives clang's answer,
# on the CPU and the GPU. Skipped where there is no clang.
#
#   bash tests/par/guard-bound.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version >/dev/null 2>&1; then
    echo "--- guard-bound: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
SRC=tests/par/c-bound/bound.c
fail=0
clang -O2 -w -o "$W/ref" "$SRC" || { echo "FAIL guard-bound: clang does not build it"; exit 1; }
want=$("$W/ref")
XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 -H . -o "$W/x" "$SRC" > "$W/b" 2>&1 \
    || { echo "FAIL guard-bound: does not build"; head -3 "$W/b"; exit 1; }
for m in VALUE MIXED UPTO STEP; do
    line=$(grep -n "LOOP-$m" "$SRC" | cut -d: -f1)
    grep -q -E "outline: [A-Za-z]+:$line: outlined, a block" "$W/b" \
        || { echo "FAIL guard-bound: the $m loop (line $line) did not become a guarded block"; grep -E ":$line:" "$W/b" | head -3; fail=1; }
done
for d in cpu gpu; do
    XC_PAR=$d XC_PAR_REPORT=1 "$W/x" > "$W/r.$d" 2>&1
    got=$(grep -v '^par: ' "$W/r.$d")
    [ "$got" = "$want" ] || { echo "FAIL guard-bound: $d gives '$got', clang's '$want'"; fail=1; }
    [ $d = gpu ] && continue
    for m in VALUE MIXED UPTO STEP; do
        line=$(grep -n "LOOP-$m" "$SRC" | cut -d: -f1)
        runs=$(grep -c "bound.c:$line: [0-9]* items on" "$W/r.$d")
        [ "$runs" = 2 ] || { echo "FAIL guard-bound: $d ran the $m loop as a block $runs times of its 3 calls (want 2: not the overlapping one)"; grep "bound.c:$line" "$W/r.$d"; fail=1; }
    done
done
[ $fail = 0 ] && { echo "--- guard-bound: pass ---"; exit 0; }
echo "--- guard-bound: FAIL ---"
exit 1
