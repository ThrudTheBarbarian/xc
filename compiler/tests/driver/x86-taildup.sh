#!/bin/bash
# x86-taildup.sh — a jump to a short block that ends in a jump becomes a copy
# of that block (#42, #41). The block order is a reverse postorder, so sieve's
# latch (bb_13_join) sat after the arm that sieves, and the common path, a
# composite number, took two jumps a trip: `jmp join`, then join's `jmp
# for_body`. With the latch copied into the loop body that path takes one.
# One thread on Zen 5: sieve 892 -> 761 ms (C++ GCC: 750), poly_dispatch
# 429 -> 407, sort_small 900 -> 886.
#
# sieve's loop body ends in a jump back to itself, the two compilers print the
# same code for sieve, sort_small and poly_dispatch, and on an x86-64 Linux
# host sieve gives its checksum.
#
#   bash tests/driver/x86-taildup.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
D=../benchmark/src
[ -f "$D/sieve.xc" ] || { echo "x86-taildup: no benchmark sources, skipped"; exit 0; }
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for n in sieve sort_small poly_dispatch; do
    for c in "$REF" "$XC"; do
        [ -x "$c" ] || continue
        "$c" -q -A x86_64 -O2 -H . -I "$D" -S -o "$W/$n.$(basename "$c").s" "$D/$n.xc" || { echo "FAIL $c: no assembly for $n"; fail=1; }
    done
    if [ -s "$W/$n.xcc.s" ] && [ -s "$W/$n.xcc-xc.s" ] && ! cmp -s "$W/$n.xcc.s" "$W/$n.xcc-xc.s"; then echo "FAIL: the two compilers' code for $n differs"; fail=1; fi
done
S="$W/sieve.$(basename "$XC").s"
last=$(awk '/^\.L_main_bb_10_for_body:/ {on = 1; next} on && /^\.L/ {exit} on && /\tjmp\t/ {j = $2} END {print j}' "$S")
[ "$last" = ".L_main_bb_10_for_body" ] || { echo "FAIL: sieve's loop body ends in 'jmp $last', want a jump back to .L_main_bb_10_for_body"; fail=1; }
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; then
    "$XC" -q -A x86_64 -O2 -H . -I "$D" -o "$W/sieve" "$D/sieve.xc" || { echo "FAIL: build"; fail=1; }
    got=$(XC_PAR=cpu XC_PAR_THREADS=1 "$W/sieve" x 2>/dev/null | cut -d' ' -f1)
    [ "$got" = 154350000 ] || { echo "FAIL: sieve gives $got, want 154350000"; fail=1; }
fi
[ $fail = 0 ] && echo "x86-taildup: ok"
exit $fail
