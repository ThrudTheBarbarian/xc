#!/bin/bash
# checked-ifconv.sh — a checked build whose checks all come out compiles as
# the unchecked one (2026-10-25). If-conversion ran before bounds-elide, so
# an `if` body with an a[i] check in it was a call and stayed a branch, even
# once bounds-elide proved the check away: branch_mix's main kept its four
# conditional updates as branches checked and selects unchecked. Now a
# function checks came out of gets dead-code removal, the cross-block load
# CSE and if-conversion again. branch_mix's main has the same selects
# checked as unchecked, and the two compilers print the same code.
#
#   bash tests/driver/checked-ifconv.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
SRC=../benchmark/src/branch_mix.xc
[ -f "$SRC" ] || { echo "checked-ifconv: no benchmark/src/branch_mix.xc, skipped"; exit 0; }
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
mainof() { awk '/function main\(/,/^  }/' "$1"; }
"$XC" -q -O2 -H . -I ../benchmark/src --emit-ir-opt -o "$W/u" "$SRC" 2> "$W/u.ir"
"$XC" -q -O2 -fbounds-check=light -H . -I ../benchmark/src --emit-ir-opt -o "$W/c" "$SRC" 2> "$W/c.ir"
su=$(mainof "$W/u.ir" | grep -c ' = Select ')
sc=$(mainof "$W/c.ir" | grep -c ' = Select ')
kc=$(mainof "$W/c.ir" | grep -c '_xt_check_bounds')
[ "$kc" = 0 ] || { echo "FAIL checked-ifconv: $kc checks left in main"; fail=1; }
[ "$su" -gt 0 ] && [ "$sc" = "$su" ] || { echo "FAIL checked-ifconv: main has $sc selects checked, $su unchecked"; fail=1; }
for a in arm64 x86_64; do
    for c in "$REF" "$XC"; do
        [ -x "$c" ] || continue
        "$c" -q -A $a -O2 -fbounds-check=light -H . -I ../benchmark/src -S -o "$W/$a.$(basename "$c").s" "$SRC" \
            || { echo "FAIL checked-ifconv: $c builds no $a"; fail=1; }
    done
    if [ -s "$W/$a.xcc.s" ] && [ -s "$W/$a.xcc-xc.s" ] && ! cmp -s "$W/$a.xcc.s" "$W/$a.xcc-xc.s"; then
        echo "FAIL checked-ifconv: the two compilers' checked $a code differs"; fail=1
    fi
done
[ $fail = 0 ] && echo "checked-ifconv: ok ($sc selects checked and unchecked)"
exit $fail
