#!/bin/bash
# cpp-unwind.sh — a C++ exception passes through a function xcc compiled.
# tests/par/c-unwind/apply.c (C, compiled by xcc) calls cb, a C++ function in
# thrower.cpp that throws; run() catches it after apply and checks that the
# values it keeps in callee-saved registers survived (1133 ok). Each file is
# compiled with -c and the objects linked by xcc, nothing named (each object
# says what it links). xcc's functions carry an __eh_frame / .eh_frame (C/C++
# input), which the link merges. Skipped without clang++; on x86-64 Linux
# until its back end reports its saves.
#
#   bash tests/par/cpp-unwind.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang++ --version >/dev/null 2>&1; then
    echo "--- cpp-unwind: skipped (no clang++) ---"
    exit 0
fi
if [ "$PLAT" = linux ] && [ "$(uname -m)" = x86_64 ]; then
    echo "--- cpp-unwind: skipped (x86-64 Linux: the back end reports no saves yet) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
D=tests/par/c-unwind
"$XC" -q -O3 -H . -c -o "$W/apply.o" "$D/apply.c" > "$W/b1" 2>&1 || { echo "FAIL cpp-unwind: apply.c does not build"; head -3 "$W/b1"; exit 1; }
"$XC" -q -O3 -H . -c -o "$W/thrower.o" "$D/thrower.cpp" > "$W/b2" 2>&1 || { echo "FAIL cpp-unwind: thrower.cpp does not build"; head -3 "$W/b2"; exit 1; }
"$XC" -q -O3 -H . -o "$W/x" "$W/thrower.o" "$W/apply.o" > "$W/b3" 2>&1 \
    || { echo "FAIL cpp-unwind: the objects do not link"; head -3 "$W/b3"; exit 1; }
got=$("$W/x" 2>&1)
[ "$got" = "1133 ok" ] && { echo "--- cpp-unwind: pass ---"; exit 0; }
echo "FAIL cpp-unwind: gives '$got' (want '1133 ok': the exception through xcc's apply, callee-saved values intact)"
echo "--- cpp-unwind: FAIL ---"
exit 1
