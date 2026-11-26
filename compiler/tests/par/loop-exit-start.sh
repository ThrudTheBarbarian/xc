#!/bin/bash
# loop-exit-start.sh — a C/C++ counted loop whose count starts below zero
# runs every iteration (2026-11-26). The C/C++ path rewrites clang's
# `icmp eq i, n` exit test as `i < n` for the outliner: unsigned only for a
# start of a constant 0 or more or a `nuw` step, signed for an `nsw` step.
# Before, any start became `i <u n`, so b = -2..2 ran no iteration.
#
# tests/par/c-loop-start/negstart.cpp: a constant start of -2 and a start
# known at run time (-3), each in a try. Must give clang++'s output.
# Skipped without clang++.
#
#   bash tests/par/loop-exit-start.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang++ --version >/dev/null 2>&1; then echo "--- loop-exit-start: skipped (no clang++) ---"; exit 0; fi
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/par/c-loop-start/negstart.cpp
fail=0
clang++ -O2 -o "$W/ref" "$F" || { echo "FAIL loop-exit-start: clang++ does not build it"; exit 1; }
want=$("$W/ref")
for O in -O0 -O2; do
    "$XC" -q $O -H . -o "$W/x" "$F" > "$W/b" 2>&1 || { echo "FAIL loop-exit-start $O: does not build"; grep -v warning "$W/b" | head -3; fail=1; continue; }
    got=$("$W/x" 2>&1)
    [ "$got" = "$want" ] || { echo "FAIL loop-exit-start $O: gives '$got', clang++'s '$want'"; fail=1; }
done
[ $fail = 0 ] && echo "--- loop-exit-start: pass ---" || echo "--- loop-exit-start: FAIL ---"
exit $fail
