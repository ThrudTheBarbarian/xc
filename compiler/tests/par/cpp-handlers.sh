#!/bin/bash
# cpp-handlers.sh — C++ exception handlers compiled by xcc (option (a) phase
# 2): tests/par/c-handlers/sumsafe.cpp, a loop around a try with two catches,
# and allocsum.cpp, whose fill invokes a constructor with a global's address
# (made before the call, as a constant operand's Const is), give clang++'s
# answer, and on arm64 macOS (whose back end writes the LSDA and the zPLR CIE)
# xcc takes sumsafe and every function of allocsum.cpp itself.
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
F=tests/par/c-handlers/allocsum.cpp
clang++ -O2 -o "$W/ref2" "$F" || { echo "FAIL cpp-handlers: clang++ does not build allocsum"; exit 1; }
want=$("$W/ref2")
XC_C_TRACE=1 "$XC" -q -O2 -H . -o "$W/x2" "$F" > "$W/b2" 2>&1 || { echo "FAIL cpp-handlers: allocsum does not build"; grep -v warning "$W/b2" | head -3; exit 1; }
got=$("$W/x2" 2>&1)
[ "$got" = "$want" ] || { echo "FAIL cpp-handlers: allocsum gives '$got', clang++'s '$want'"; fail=1; }
if [ "$PLAT" = osx ] && [ "$(uname -m)" = arm64 ] && grep -q 'left to clang:' "$W/b2"; then
    echo "FAIL cpp-handlers: allocsum.cpp has functions left to clang"; grep 'because of' "$W/b2" | head -2; fail=1
fi
[ $fail = 0 ] && echo "--- cpp-handlers: pass ---" || echo "--- cpp-handlers: FAIL ---"
exit $fail
