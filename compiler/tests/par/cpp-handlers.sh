#!/bin/bash
# cpp-handlers.sh — C++ exception handlers compiled by xcc (option (a) phase
# 2): tests/par/c-handlers/sumsafe.cpp, a loop around a try with two catches,
# and allocsum.cpp, whose fill invokes a constructor with a global's address
# (made before the call, as a constant operand's Const is), and
# twopads.cpp, whose cleanups clang merges into one resume of a phi of
# the pad pair, and virtcall.cpp, a virtual call and a function pointer's in
# a try (invokes through a pointer), and padphi.cpp, whose landing pad starts
# with a phi, give clang++'s answer, and on arm64 macOS (whose back end
# writes the LSDA and the zPLR CIE) xcc takes sumsafe and every function of
# the other four itself.
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
for b in allocsum twopads virtcall padphi; do
    F=tests/par/c-handlers/$b.cpp
    clang++ -O2 -o "$W/ref.$b" "$F" || { echo "FAIL cpp-handlers: clang++ does not build $b"; fail=1; continue; }
    want=$("$W/ref.$b")
    XC_C_TRACE=1 "$XC" -q -O2 -H . -o "$W/x.$b" "$F" > "$W/b.$b" 2>&1 || { echo "FAIL cpp-handlers: $b does not build"; grep -v warning "$W/b.$b" | head -3; fail=1; continue; }
    got=$("$W/x.$b" 2>&1)
    [ "$got" = "$want" ] || { echo "FAIL cpp-handlers: $b gives '$got', clang++'s '$want'"; fail=1; }
    if [ "$PLAT" = osx ] && [ "$(uname -m)" = arm64 ] && grep -q 'left to clang:' "$W/b.$b"; then
        echo "FAIL cpp-handlers: $b.cpp has functions left to clang"; grep 'because of' "$W/b.$b" | head -2; fail=1
    fi
done
[ $fail = 0 ] && echo "--- cpp-handlers: pass ---" || echo "--- cpp-handlers: FAIL ---"
exit $fail
