#!/bin/bash
# overlap-gather.sh — the overlap guard for a gather: a loop that stores y[i]
# and reads x[idx[i]] (x never stored in it) is a guarded block. With x and y
# in different heap blocks it runs as a block; with them in one block (the
# gather reaching back into the y being written, which only a serial run gets
# right) it runs serially. Each run, CPU and GPU, gives clang's answer.
# Skipped where there is no clang.
#
#   bash tests/par/overlap-gather.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version >/dev/null 2>&1; then
    echo "--- overlap-gather: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
SRC=tests/par/c-gather/gather.c
fail=0
clang -O2 -w -o "$W/ref" "$SRC" || { echo "FAIL overlap-gather: clang does not build it"; exit 1; }
want=$("$W/ref")
XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 -H . -o "$W/x" "$SRC" > "$W/b" 2>&1 \
    || { echo "FAIL overlap-gather: does not build"; head -3 "$W/b"; exit 1; }
grep -q 'gather:[0-9]*: outlined, a block' "$W/b" || { echo "FAIL overlap-gather: the gather did not become a guarded block"; grep 'gather' "$W/b" | head -3; fail=1; }
for d in cpu gpu; do
    got=$(XC_PAR=$d "$W/x")
    [ "$got" = "$want" ] || { echo "FAIL overlap-gather: $d gives $got, clang's $want"; fail=1; }
done
[ $fail = 0 ] && echo "--- overlap-gather: pass ---" || echo "--- overlap-gather: FAIL ---"
exit $fail
