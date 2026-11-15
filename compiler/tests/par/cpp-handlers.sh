#!/bin/bash
# cpp-handlers.sh — C++ exception handlers compiled by xcc (option (a) phase
# 2): tests/par/c-handlers/sumsafe.cpp, a loop around a try with two catches,
# gives clang++'s answer, and on arm64 macOS (whose back end writes the LSDA
# and the zPLR CIE) xcc takes sumsafe itself: nothing left to clang.
# Skipped without clang++.
#
#   bash tests/par/cpp-handlers.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang++ --version >/dev/null 2>&1; then echo "--- cpp-handlers: skipped (no clang++) ---"; exit 0; fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
F=tests/par/c-handlers/sumsafe.cpp
fail=0
clang++ -O2 -o "$W/ref" "$F" || { echo "FAIL cpp-handlers: clang++ does not build it"; exit 1; }
want=$("$W/ref")
XC_C_TRACE=1 "$XC" -q -O2 -H . -o "$W/x" "$F" > "$W/b" 2>&1 || { echo "FAIL cpp-handlers: does not build"; grep -v warning "$W/b" | head -3; exit 1; }
got=$("$W/x" 2>&1)
[ "$got" = "$want" ] || { echo "FAIL cpp-handlers: gives '$got', clang++'s '$want'"; fail=1; }
if [ "$PLAT" = osx ] && [ "$(uname -m)" = arm64 ] && grep -q 'left to clang: @_Z7sumsafei' "$W/b"; then
    echo "FAIL cpp-handlers: sumsafe was left to clang"; grep 'first because' "$W/b" | head -2; fail=1
fi
[ $fail = 0 ] && echo "--- cpp-handlers: pass ---" || echo "--- cpp-handlers: FAIL ---"
exit $fail
