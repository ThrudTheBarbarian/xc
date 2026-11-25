#!/bin/bash
# c-atomics.sh — C and C++ atomics read by xcc rather than left to clang:
# atomicrmw (xchg, add, sub, and, or, xor), cmpxchg, fence and atomic
# load/store, of 8 to 64 bits and pointers, at every memory order.
#
# tests/par/c-atomics/atoms.c (C11 <stdatomic.h>, four pthreads) is built
# and atoms.cpp (std::atomic, a compare-exchange loop, shared_ptr copies,
# four std::threads) are each built with no function left to clang.
# Each must print what clang's build prints, at -O0 and -O2. Natively on
# arm64 macOS and Linux and x86-64 Linux; with Wine and the mingw root,
# atoms.cpp also for win64 (the x86-64 back end). Skipped without clang.
#
#   bash tests/par/c-atomics.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
PT=$( [ $PLAT = linux ] && echo -pthread )
if ! clang++ --version >/dev/null 2>&1; then echo "--- c-atomics: skipped (no clang) ---"; exit 0; fi
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
C=tests/par/c-atomics/atoms.c
CXX=tests/par/c-atomics/atoms.cpp
clang -O2 $PT -o "$W/ref.c" "$C" || { echo "FAIL c-atomics: clang does not build atoms.c"; exit 1; }
clang++ -std=c++20 -O2 $PT -o "$W/ref.cpp" "$CXX" || { echo "FAIL c-atomics: clang++ does not build atoms.cpp"; exit 1; }
# name, source, clang's binary
one() {
    local name=$1 src=$2 ref=$3 O got want
    want=$("$ref" 2>&1)
    for O in -O0 -O2; do
        if ! XC_C_TRACE=1 "$XC" -q $O -H . -o "$W/x" "$src" > "$W/b" 2>&1; then
            echo "FAIL c-atomics: $name $O does not build"; grep -v warning "$W/b" | head -3; fail=1; continue
        fi
        got=$("$W/x" 2>&1)
        [ "$got" = "$want" ] || { echo "FAIL c-atomics: $name $O gives '$got', clang's '$want'"; fail=1; }
        if grep -q 'because of' "$W/b"; then
            echo "FAIL c-atomics: $name $O left to clang:"; grep 'because of' "$W/b" | head -4; fail=1
        fi
    done
}
one atoms.c "$C" "$W/ref.c"
one atoms.cpp "$CXX" "$W/ref.cpp"
# win64 under Wine: the x86-64 back end's atomics.
ROOT=/opt/clang/win64/x86_64-w64-mingw32
if command -v wine >/dev/null 2>&1 && [ -f "$ROOT/lib/libc++.a" ]; then
    export WINEPREFIX=${WINEPREFIX:-$HOME/.wine-gates} WINEDLLOVERRIDES="winedbg.exe=d" WINEDEBUG=-all
    want=$("$W/ref.cpp" 2>&1)
    for O in -O0 -O2; do
        if XC_C_TRACE=1 "$XC" -q $O -H . -A win64 -o "$W/xw.exe" "$CXX" > "$W/b" 2>&1; then
            got=$(timeout 120 wine "$W/xw.exe" 2>/dev/null | tr -d '\r')
            [ "$got" = "$want" ] || { echo "FAIL c-atomics: atoms.cpp $O (win64) gives '$got', clang's '$want'"; fail=1; }
            if grep -q 'because of' "$W/b"; then
                echo "FAIL c-atomics: atoms.cpp $O (win64) left to clang:"; grep 'because of' "$W/b" | head -4; fail=1
            fi
        else echo "FAIL c-atomics: atoms.cpp $O does not build for win64"; grep -v warning "$W/b" | head -3; fail=1; fi
    done
fi
[ $fail = 0 ] && echo "--- c-atomics: pass ---" || echo "--- c-atomics: FAIL ---"
exit $fail
