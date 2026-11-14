#!/bin/bash
# cpp-unwind.sh — a C++ exception passes through a function xcc compiled.
# tests/par/c-unwind/apply.c (C, compiled by xcc) calls cb, a C++ function in
# thrower.cpp that throws; run() catches it after apply and checks that the
# values it keeps in callee-saved registers survived (1133 ok). Each file is
# compiled with -c and the objects linked by xcc (the runtime's frameworks and
# libc++ named, as an object link needs them). xcc's functions carry an
# __eh_frame (C/C++ input), which the link merges. macOS only for now;
# skipped without clang++.
#
#   bash tests/par/cpp-unwind.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if [ "$PLAT" != osx ] || ! clang++ --version >/dev/null 2>&1; then
    echo "--- cpp-unwind: skipped (macOS with clang++ only) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
D=tests/par/c-unwind
"$XC" -q -O3 -H . -c -o "$W/apply.o" "$D/apply.c" > "$W/b1" 2>&1 || { echo "FAIL cpp-unwind: apply.c does not build"; head -3 "$W/b1"; exit 1; }
"$XC" -q -O3 -H . -c -o "$W/thrower.o" "$D/thrower.cpp" > "$W/b2" 2>&1 || { echo "FAIL cpp-unwind: thrower.cpp does not build"; head -3 "$W/b2"; exit 1; }
"$XC" -q -O3 -H . -o "$W/x" "$W/thrower.o" "$W/apply.o" -framework CoreFoundation -framework Metal -framework Foundation -lc++ > "$W/b3" 2>&1 \
    || { echo "FAIL cpp-unwind: the objects do not link"; head -3 "$W/b3"; exit 1; }
got=$("$W/x" 2>&1)
[ "$got" = "1133 ok" ] && { echo "--- cpp-unwind: pass ---"; exit 0; }
echo "FAIL cpp-unwind: gives '$got' (want '1133 ok': the exception through xcc's apply, callee-saved values intact)"
echo "--- cpp-unwind: FAIL ---"
exit 1
