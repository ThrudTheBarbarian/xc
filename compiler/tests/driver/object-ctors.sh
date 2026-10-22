#!/bin/bash
# object-ctors.sh — an object keeps its load-time constructors (2026-10-22). A
# designable class registers itself from a load-time constructor; built with
# -c and then linked, the arm64 object used to carry no __mod_init_func and
# the link merged none, so the registration never ran and a nib could not
# make the class. Built as one object and linked, the program must print what
# it prints built whole. On a Mac the object is checked for the section too.
#
#   bash tests/driver/object-ctors.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
F=tests/fixtures/designable_register
"$XC" -q -O2 -H . -c -o "$W/d.o" "$F.xc" > "$W/b" 2>&1 || { echo "FAIL object-ctors: -c does not build"; head -3 "$W/b"; exit 1; }
"$XC" -q -O2 -H . -o "$W/d" "$W/d.o" > "$W/b" 2>&1 || { echo "FAIL object-ctors: the object does not link"; head -3 "$W/b"; exit 1; }
"$W/d" > "$W/out" 2>&1
cmp -s "$W/out" "$F.expected.out" || { echo "FAIL object-ctors: linked from its object it prints"; head -3 "$W/out"; fail=1; }
if [ "$PLAT" = osx ] && command -v otool > /dev/null; then
    otool -l "$W/d.o" | grep -q '__mod_init_func' || { echo "FAIL object-ctors: the object has no __mod_init_func"; fail=1; }
fi
[ $fail = 0 ] && echo "--- object-ctors: pass ---" || { echo "--- object-ctors: FAIL ---"; exit 1; }
