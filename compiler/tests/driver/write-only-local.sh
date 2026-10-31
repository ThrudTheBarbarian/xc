#!/bin/bash
# write-only-local.sh — stores to a local nothing reads are dropped (2026-10-31)
#
# struct_copy's `p = bump(p, r)` left, after inlining, two stores a turn to
# p's frame slot that nothing loaded: 11 instructions a turn against clang's
# 6, and 1.69x clang on a Raspberry Pi 5. The dead-code pass now drops every
# store to a slot that does not escape and whose address is used only as a
# store's address. Checked on tests/fixtures/write_only_local.xc: main's first
# loop keeps no Store, the slot that reaches a call and the one read back keep
# theirs (the program prints the same), and the two compilers write the same
# assembly.
#
#   bash tests/driver/write-only-local.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/write_only_local.xc
fail=0
# (--emit-ir-opt exits with a fault after writing the IR, 0.89 too: TODO.)
"$XC" -q -O2 --emit-ir-opt "$F" > "$W/ir" 2>&1
grep -q "function main(" "$W/ir" || { echo "FAIL write-only-local: no IR"; exit 1; }
left=$(awk '/function main\(/,/^  }/' "$W/ir" | awk '/bb_1_for_body:/,/CondBranch/' | grep -c ' = Store ')
[ "$left" = 0 ] || { echo "FAIL write-only-local: $left stores left in the first loop"; fail=1; }
for s in r x; do
    c=$REF; [ $s = x ] && c=$XC
    "$c" -q -O2 -S -o "$W/$s.s" "$F" > "$W/e" 2>&1 || { echo "FAIL write-only-local: $(basename "$c") does not compile it"; fail=1; }
done
[ $fail = 0 ] && { cmp -s "$W/r.s" "$W/x.s" || { echo "FAIL write-only-local: the two compilers' assembly differs"; fail=1; }; }
if [ $fail = 0 ] && [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
    for o in O0 O2; do
        "$XC" -q -$o -o "$W/p$o" "$F" && "$W/p$o" > "$W/out$o" || { echo "FAIL write-only-local: -$o build fails"; fail=1; }
    done
    cmp -s "$W/outO0" tests/fixtures/write_only_local.expected.out && cmp -s "$W/outO2" tests/fixtures/write_only_local.expected.out \
        || { echo "FAIL write-only-local: the program prints something else"; fail=1; }
fi
[ $fail = 0 ] && echo "write-only-local: ok"
exit $fail
