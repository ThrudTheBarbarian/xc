#!/bin/bash
# overlap-gather.sh — the overlap guard for a gather: a loop that stores y[i]
# and reads x[idx[i]] (x never stored in it) is a guarded block. With x and y
# in different heap blocks it runs as a block; with them in one block (the
# gather reaching back into the y being written, which only a serial run gets
# right) it runs serially. Each run, CPU and GPU, gives clang's answer, and
# the par report shows the block run for one of the two calls.
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
    # The par report (on stdout, its lines starting "par:"): of the two
    # calls the gather's block runs once, for the apart one; the guard keeps
    # the one-block call serial before the runtime sees it.
    XC_PAR=$d XC_PAR_REPORT=1 "$W/x" > "$W/r.$d" 2>&1
    runs=$(grep -c 'gather.c:11: [0-9]* items on' "$W/r.$d")
    # x[idx[i]] cannot be bounded, so the guard asks Par.spanOf for the two
    # heap blocks, which the runtime allocated (64 KB and more, #235).
    [ "$runs" = 1 ] || { echo "FAIL overlap-gather: $d ran the gather as a block $runs times of its 2 calls (want 1)"; grep 'gather.c:11' "$W/r.$d"; fail=1; }
done
# How spanOf sees malloc's blocks (#235, #268), on the CPU. With blocks of
# 64 KB and more (n 100000), which the runtime allocated: x and y in two
# blocks run as a block, x taken from its block's start (a) or from inside it
# (m, 64 elements in; p, 4096 bytes in), since a pointer into a block is sized
# to the block's end. y inside x's block runs serially (i; q, 4096 bytes in).
# Blocks under 64 KB (n 4000) are the C library's, unknown: all serial. A
# -static Linux program (musl) knows no malloc block: all serial.
SPANS=tests/par/c-gather/spans.c
clang -O2 -w -o "$W/sref" "$SPANS" || { echo "FAIL overlap-gather: clang does not build spans.c"; exit 1; }
"$XC" -q -O3 -H . -o "$W/s" "$SPANS" > "$W/sb" 2>&1 || { echo "FAIL overlap-gather: spans.c does not build"; head -3 "$W/sb"; exit 1; }
builds=s
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; then
    "$XC" -q -O3 -static -H . -o "$W/s.static" "$SPANS" > "$W/sb" 2>&1 || { echo "FAIL overlap-gather: spans.c does not build -static"; head -3 "$W/sb"; exit 1; }
    builds="s s.static"
fi
for b in $builds; do
    for n in 4000 100000; do
        for c in a m p i q; do
            want=$("$W/sref" $n $c)
            XC_PAR=cpu XC_PAR_REPORT=1 "$W/$b" $n $c > "$W/sr" 2>&1
            got=$(grep -v '^par: ' "$W/sr" | tail -1)
            [ "$got" = "$want" ] || { echo "FAIL overlap-gather: $b $n $c gives $got, clang's $want"; fail=1; }
            runs=$(grep -c 'spans.c:17: [0-9]* items on' "$W/sr")
            want_runs=0
            case $c in a|m|p) [ $b = s ] && [ $n = 100000 ] && want_runs=1 ;; esac
            [ "$runs" = "$want_runs" ] || { echo "FAIL overlap-gather: $b $n $c ran the gather as a block $runs times (want $want_runs)"; fail=1; }
        done
    done
done
[ $fail = 0 ] && echo "--- overlap-gather: pass ---" || echo "--- overlap-gather: FAIL ---"
exit $fail
