#!/bin/bash
# vector-bound.sh — a loop whose bound and bases are loaded each pass from
# addresses it does not move (a std::vector's begin and end, `i < *n`): the
# call site reads them once and the block runs where no store of the loop
# reaches them; the loop as written runs where one may. Each loop of
# c-vbound/vbound.cpp is a block and gives clang++'s answer on the CPU and
# GPU; c-vbound/bound.c's loop runs as a block for its apart call only, and
# the call whose stores reach its bound gives clang's answer.
# Skipped where there is no clang.
#
#   bash tests/par/vector-bound.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang++ --version >/dev/null 2>&1; then
    echo "--- vector-bound: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
# The C++ loops.
SRC=tests/par/c-vbound/vbound.cpp
clang++ -std=c++17 -O2 -w -o "$W/ref" "$SRC" || { echo "FAIL vector-bound: clang++ does not build vbound.cpp"; exit 1; }
want=$("$W/ref")
XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 -std=c++17 -H . -o "$W/x" "$SRC" > "$W/b" 2>&1 \
    || { echo "FAIL vector-bound: vbound.cpp does not build"; head -3 "$W/b"; exit 1; }
for f in fill look both; do
    grep -q "$f.*: outlined, a block" "$W/b" || { echo "FAIL vector-bound: $f did not become a block"; grep "$f" "$W/b" | head -3; fail=1; }
done
for d in cpu gpu; do
    got=$(XC_PAR=$d "$W/x")
    [ "$got" = "$want" ] || { echo "FAIL vector-bound: vbound.cpp on $d gives $got, clang++'s $want"; fail=1; }
done
# The C loop, its bound inside the array it stores for one of its two calls.
SRC=tests/par/c-vbound/bound.c
clang -O2 -w -o "$W/cref" "$SRC" || { echo "FAIL vector-bound: clang does not build bound.c"; exit 1; }
want=$("$W/cref")
"$XC" -q -O3 -H . -o "$W/c" "$SRC" > "$W/cb" 2>&1 || { echo "FAIL vector-bound: bound.c does not build"; head -3 "$W/cb"; exit 1; }
for d in cpu gpu; do
    got=$(XC_PAR=$d "$W/c")
    [ "$got" = "$want" ] || { echo "FAIL vector-bound: bound.c on $d gives $got, clang's $want"; fail=1; }
    # The par report (stdout, lines starting "par:"): zap's block runs for
    # the first call only.
    XC_PAR=$d XC_PAR_REPORT=1 "$W/c" > "$W/r.$d" 2>&1
    runs=$(grep -c 'bound.c:8: [0-9]* items' "$W/r.$d")
    [ "$runs" = "1" ] || { echo "FAIL vector-bound: $d ran zap as a block $runs times of its 2 calls (want 1)"; grep 'bound.c:8' "$W/r.$d"; fail=1; }
done
[ $fail = 0 ] && echo "--- vector-bound: pass ---" || echo "--- vector-bound: FAIL ---"
exit $fail
