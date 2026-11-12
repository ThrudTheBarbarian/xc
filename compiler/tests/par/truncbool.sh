#!/bin/bash
# truncbool.sh — `trunc iN %x to i1` is the low bit of x (#155). The reader is
# given tests/par/c-ll/trunc-bool.ll (clang's switch-to-bit-test lowering:
# `lshr i8 -107, %r` then `trunc ... to i1`) through XC_C_LL; the count must be
# clang's 19 with the loop left plain (--par-style=cpu) and lifted, on the CPU.
# Skipped where there is no clang. Self-hosted compiler only.
#
#   bash tests/par/truncbool.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version >/dev/null 2>&1; then
    echo "--- truncbool: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
LL=$PWD/tests/par/c-ll/trunc-bool.ll
fail=0
echo 'int main(void) { return 0; }' > "$W/stub.c"
for ps in cpu auto; do
    XC_C_LL="$LL" "$XC" -q -O3 --par-style=$ps -H . -o "$W/t.$ps" "$W/stub.c" > "$W/b.$ps" 2>&1 \
        || { echo "FAIL truncbool: does not build (--par-style=$ps)"; head -3 "$W/b.$ps"; fail=1; continue; }
    got=$(XC_PAR=cpu "$W/t.$ps")
    [ "$got" = "19" ] || { echo "FAIL truncbool: --par-style=$ps gives $got, clang's 19"; fail=1; }
done
[ $fail = 0 ] && echo "--- truncbool: pass ---" || echo "--- truncbool: FAIL ---"
exit $fail
