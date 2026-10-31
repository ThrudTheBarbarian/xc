#!/bin/bash
# cmp-wide-imm.sh — arm64: a loop's wide compare immediate lives in a register
# (2026-10-31)
#
# arm64's cmp takes a 12-bit immediate, optionally shifted by 12. A loop bound
# such as 2200000000 was rebuilt with movz + movk on every turn (struct_copy's
# one-block loop: 9 instructions where clang has 7). ConstHoist (arm64's
# profile, hoistsWideCmpImm) makes such an immediate a Const in the preheader,
# for a one-block loop as for a longer one. Checked on
# tests/fixtures/cmp_wide_imm.xc (a loop bounded by 70000, which cmp cannot
# take either): no movk inside the loop, the two
# compilers write the same assembly, and the answers are those of -O0.
#
#   bash tests/driver/cmp-wide-imm.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/cmp_wide_imm.xc
fail=0
for s in r x; do
    c=$REF; [ $s = x ] && c=$XC
    "$c" -q -O2 -A arm64 -S -o "$W/$s.s" "$F" > "$W/e" 2>&1 || { echo "FAIL cmp-wide-imm: $(basename "$c") does not compile it"; fail=1; }
done
[ $fail = 0 ] && { cmp -s "$W/r.s" "$W/x.s" || { echo "FAIL cmp-wide-imm: the two compilers' assembly differs"; fail=1; }; }
# The loop's body label (`_vu0` once unrolled) down to its back branch.
n=$(awk '/^Lmain_bb_1_for_body[_a-z0-9]*:/{p=1} p{print} p && /b\.(lo|lt|ne) Lmain_bb_1_for_body/{exit}' "$W/x.s" | grep -c 'movk')
[ "$n" = 0 ] || { echo "FAIL cmp-wide-imm: the loop still rebuilds its bound ($n movk)"; fail=1; }
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
    for o in O0 O2 O3; do
        "$XC" -q -$o -o "$W/p$o" "$F" && "$W/p$o" > "$W/out$o" \
            && cmp -s "$W/out$o" tests/fixtures/cmp_wide_imm.expected.out || { echo "FAIL cmp-wide-imm: -$o prints $(cat "$W/out$o" 2>/dev/null)"; fail=1; }
    done
fi
[ $fail = 0 ] && echo "cmp-wide-imm: ok"
exit $fail
