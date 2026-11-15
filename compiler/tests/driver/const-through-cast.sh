#!/bin/bash
# const-through-cast.sh — a constant divisor or element index reached through
# a narrowing cast is the converted value (#308). The code generators followed
# ZExt/SExt/Trunc back to the literal without applying them, so at -O0/-O1
# `x / (i32)(i8)300` divided by 300 (want 44) and `arr[(u8)300]` read arr[300].
# tests/fixtures/const_through_cast.xc at -O0, -O1 and -O2 with both compilers,
# run where the target is the host (arm64 macOS, x86-64 Linux).
#
#   bash tests/driver/const-through-cast.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
F=tests/fixtures/const_through_cast
want=$(cat "$F.expected.out")
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    for o in -O0 -O1 -O2; do
        "$c" -q $o -H . -o "$W/t" "$F.xc" || { echo "FAIL $(basename "$c") $o: no build"; fail=1; continue; }
        got=$("$W/t")
        [ "$got" = "$want" ] || { echo "FAIL $(basename "$c") $o: '$got', want '$want'"; fail=1; }
    done
done
[ $fail = 0 ] && echo "const-through-cast: ok"
exit $fail
