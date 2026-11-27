#!/bin/bash
# c-fcmp.sh — the C/C++ path's float compares, ordered and unordered, give
# clang's results, NaN included (2026-11-27). clang writes C's x != y as
# `fcmp une` (and !(x < y) as `fcmp uge`, isunordered as `fcmp uno`); the
# reader now writes each unordered compare as the negation of the ordered
# complement. Before, arm64 took `une` as `eq`: x != y was x == y, and a
# std::sort comparator built on it sorted wrongly.
#
# tests/par/c-fcmp/fcmp.c at -O0 and -O2 must print clang's output.
# Skipped without clang.
#
#   bash tests/par/c-fcmp.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version >/dev/null 2>&1; then echo "--- c-fcmp: skipped (no clang) ---"; exit 0; fi
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/par/c-fcmp/fcmp.c
fail=0
clang -O2 -o "$W/ref" "$F" -lm || { echo "FAIL c-fcmp: clang does not build it"; exit 1; }
"$W/ref" > "$W/want"
for O in -O0 -O2; do
    "$XC" -q $O -H . -o "$W/x" "$F" > "$W/b" 2>&1 || { echo "FAIL c-fcmp $O: does not build"; grep -v warning "$W/b" | head -3; fail=1; continue; }
    "$W/x" > "$W/got" 2>&1
    cmp -s "$W/want" "$W/got" || { echo "FAIL c-fcmp $O: differs from clang:"; diff "$W/want" "$W/got" | head -6; fail=1; }
done
[ $fail = 0 ] && echo "--- c-fcmp: pass ---" || echo "--- c-fcmp: FAIL ---"
exit $fail
