#!/bin/bash
# c-zeroext.sh — C's unsigned char and short across the boundary between
# functions xcc compiles and functions clang compiles (2026-10-25). LLVM marks
# such a return or parameter `zeroext`: whoever receives it reads the whole
# register. The C reader's integers are signed, so on arm64 xcc returned
# (unsigned short)65535 as -1 and passed it to clang's code so. Now a zeroext
# value crosses as U8 / U16 and is narrowed back after. Here clang compiles
# the functions with a popcount (a builtin the reader does not read) and xcc
# the others, each calling the other's; fptoui.c's to_u16 covers the return.
#
#   bash tests/driver/c-zeroext.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
command -v clang > /dev/null || { echo "--- c-zeroext: skipped (no clang) ---"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
want="1065813 1065804 2665790 2365783"
"$XC" -q -O2 -o "$W/z" tests/c/zeroext.c || { echo "FAIL c-zeroext: does not build"; exit 1; }
got=$("$W/z")
[ "$got" = "$want" ] || { echo "FAIL c-zeroext: printed '$got', want '$want'"; exit 1; }
echo "c-zeroext: ok"
