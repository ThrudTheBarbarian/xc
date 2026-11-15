#!/bin/bash
# cpp-narrow-lshr.sh — a logical right shift of a byte by a constant (clang's
# `lshr i8`, tests/par/c-narrow/hist.cpp): xcc gives clang++'s histogram.
# Skipped without clang++.
#
#   bash tests/par/cpp-narrow-lshr.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang++ --version >/dev/null 2>&1; then echo "--- cpp-narrow-lshr: skipped (no clang++) ---"; exit 0; fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
F=tests/par/c-narrow/hist.cpp
clang++ -O2 -o "$W/ref" "$F" || { echo "FAIL cpp-narrow-lshr: clang++ does not build it"; exit 1; }
want=$("$W/ref")
"$XC" -q -O3 -H . -o "$W/x" "$F" > "$W/b" 2>&1 || { echo "FAIL cpp-narrow-lshr: does not build"; grep -v warning "$W/b" | head -3; exit 1; }
got=$(XC_PAR=cpu "$W/x" 2>&1 | grep -v '^par:')
[ "$got" = "$want" ] && { echo "--- cpp-narrow-lshr: pass ---"; exit 0; }
echo "FAIL cpp-narrow-lshr: gives '$got', clang++'s '$want'"
echo "--- cpp-narrow-lshr: FAIL ---"
exit 1
