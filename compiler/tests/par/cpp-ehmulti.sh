#!/bin/bash
# cpp-ehmulti.sh — a C++ program of two files, each throwing and catching in
# its own functions (tests/par/c-ehmulti), and one exception crossing from
# one file to the other. Every object's frame table must reach the unwinder:
# on ELF the link lays them end to end under the one __register_frame. Built
# in one command and as -c objects linked; clang++'s answer each time.
# Skipped without clang++.
#
#   bash tests/par/cpp-ehmulti.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang++ --version >/dev/null 2>&1; then
    echo "--- cpp-ehmulti: skipped (no clang++) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
D=tests/par/c-ehmulti
clang++ -std=c++17 -O2 -o "$W/ref" "$D/main.cpp" "$D/other.cpp" || { echo "FAIL cpp-ehmulti: clang++ does not build it"; exit 1; }
want=$("$W/ref")
fail=0
"$XC" -q -O3 -std=c++17 -H . -o "$W/one" "$D/main.cpp" "$D/other.cpp" > "$W/b1" 2>&1 \
    || { echo "FAIL cpp-ehmulti: the one-command build fails"; grep -v warning "$W/b1" | head -3; fail=1; }
got=$("$W/one" 2>&1)
[ "$got" = "$want" ] || { echo "FAIL cpp-ehmulti: the program gives '$got', clang++'s '$want'"; fail=1; }
for f in main other; do
    "$XC" -q -O3 -std=c++17 -H . -c -o "$W/$f.o" "$D/$f.cpp" > "$W/b.$f" 2>&1 \
        || { echo "FAIL cpp-ehmulti: $f.cpp does not build"; grep -v warning "$W/b.$f" | head -3; fail=1; }
done
"$XC" -q -O3 -H . -o "$W/x" "$W/other.o" "$W/main.o" > "$W/b2" 2>&1 \
    || { echo "FAIL cpp-ehmulti: the objects do not link"; head -3 "$W/b2"; fail=1; }
got=$("$W/x" 2>&1)
[ "$got" = "$want" ] || { echo "FAIL cpp-ehmulti: the objects' program gives '$got', clang++'s '$want'"; fail=1; }
[ $fail = 0 ] && echo "--- cpp-ehmulti: pass ---" || echo "--- cpp-ehmulti: FAIL ---"
exit $fail
