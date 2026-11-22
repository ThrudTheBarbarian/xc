#!/bin/bash
# ir-indirect-branch.sh — IR text with an IndirectBranch is refused (#435). No
# front end makes one and no back end lowers one; the IR reader used to place
# it as an ordinary instruction, leaving its block with no terminator.
#
#   bash tests/driver/ir-indirect-branch.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
printf 'i32 f(i32 x) { return x + 1; }\nvoid main(void) { f(2); }\n' > "$W/f.xc"
"$XC" -q -O0 -H . --emit-ir -S -o "$W/f.s" "$W/f.xc" 2> "$W/f.ir" || { echo "FAIL ir-indirect-branch: no IR"; exit 1; }
# an IndirectBranch line just before f's Return
awk '/^  function f\(/ { inf = 1 } inf && /^      Return / && !done { print "      IndirectBranch %0"; done = 1 } { print }' "$W/f.ir" > "$W/bad.ir"
grep -q '^      IndirectBranch %0$' "$W/bad.ir" || { echo "FAIL ir-indirect-branch: test IR not made"; exit 1; }
"$XC" -q -O0 -H . -S -o "$W/f.s" "$W/f.ir" || { echo "FAIL ir-indirect-branch: the unchanged IR is not read"; fail=1; }
if "$XC" -q -O0 -H . -S -o "$W/bad.s" "$W/bad.ir" > "$W/err" 2>&1; then
    echo "FAIL ir-indirect-branch: IR with an IndirectBranch compiled"; fail=1
elif ! grep -q 'IndirectBranch is not supported' "$W/err"; then
    echo "FAIL ir-indirect-branch: refused without saying why: $(head -1 "$W/err")"; fail=1
fi
[ $fail = 0 ] && echo "ir-indirect-branch: ok"
exit $fail
