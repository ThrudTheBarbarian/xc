#!/bin/bash
# cppextract.sh — loops of a function xcc leaves to clang (main, which an
# exception may pass through: it allocates vectors) move into functions of
# their own that xcc takes and lifts (Languages.extractLoops). For
# tests/par/cpp/mainloops.cpp: at least four of main's loops become blocks
# (main$xcl<k>), and every build gives clang++'s answer on the CPU and GPU.
# Skipped where there is no clang++.
#
#   bash tests/par/cppextract.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang++ --version >/dev/null 2>&1; then
    echo "--- cppextract: skipped (no clang++) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
SRC=tests/par/cpp/mainloops.cpp
fail=0
clang++ -std=c++20 -O2 -w -o "$W/ref" "$SRC" || { echo "FAIL cppextract: clang++ does not build it"; exit 1; }
want=$("$W/ref")
XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 -std=c++20 -H . -o "$W/x" "$SRC" > "$W/b" 2>&1 \
    || { echo "FAIL cppextract: does not build"; grep -v warning "$W/b" | head -3; exit 1; }
blocks=$(grep -c 'main\$xcl[0-9]*:[0-9]*: outlined, a block' "$W/b")
[ "$blocks" -ge 4 ] || { echo "FAIL cppextract: $blocks of main's loops became blocks (want 4 or more)"; grep 'main\$xcl' "$W/b" | head -12; fail=1; }
for d in cpu gpu; do
    got=$(XC_PAR=$d "$W/x")
    [ "$got" = "$want" ] || { echo "FAIL cppextract: $d gives '$got', clang++'s '$want'"; fail=1; }
done
got=$("$W/x")
[ "$got" = "$want" ] || { echo "FAIL cppextract: gives '$got', clang++'s '$want'"; fail=1; }
[ $fail = 0 ] && echo "--- cppextract: pass ($blocks blocks in main) ---" || echo "--- cppextract: FAIL ---"
exit $fail
