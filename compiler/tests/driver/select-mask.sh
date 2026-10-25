#!/bin/bash
# select-mask.sh — a select on a masked bit is one bit test (2026-10-25,
# perlin's grad()). `(h & 7) < 4` is `(h & 4) == 0` and `(h & 7) & 1` is
# `h & 1`, so `h & 7` is dead; on x86-64 a select whose condition is
# `(x & m) == 0` or `!= 0` is `test x, m` and a branch or cmov, the And not
# emitted, and a compare read by two selects is fused into both. Before:
# `and; cmp 4; setb` and a `test` per select, and `mov; and; test` for each
# bit; C perlin 30.2 -> 25.8 G instructions, 107 -> 101 ms on one thread.
# float_select_homes.xc's grad() has no `and` and tests bits 4, 1 and 2;
# select_mask.xc and float_select_homes.xc give their answers on Linux x86-64
# (here, or on XC_LINUX_HOST); the two compilers print the same code.
#
#   bash tests/driver/select-mask.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for f in float_select_homes select_mask; do
    for c in "$REF" "$XC"; do
        [ -x "$c" ] || continue
        "$c" -q -A x86_64 -O2 -H . -S -o "$W/$f.$(basename "$c").s" tests/fixtures/$f.xc \
            || { echo "FAIL $c: no assembly for $f"; fail=1; }
    done
    if [ -s "$W/$f.xcc.s" ] && [ -s "$W/$f.xcc-xc.s" ] && ! cmp -s "$W/$f.xcc.s" "$W/$f.xcc-xc.s"; then
        echo "FAIL: the two compilers' code for $f differs"; fail=1
    fi
done
S="$W/float_select_homes.$(basename "$XC").s"
# grad() is inlined into main twice: no `and r, 7` is left, and each of
# bits 4, 1 and 2 is tested in place at both copies.
if grep -qE '^[[:space:]]*and[[:space:]]+[a-z0-9]+, 7$' "$S"; then
    echo "FAIL: grad still masks its hash with 7:"; grep -E '^[[:space:]]*and[[:space:]]+[a-z0-9]+, 7$' "$S"; fail=1
fi
for m in 4 1 2; do
    n=$(grep -cE "^[[:space:]]*test[[:space:]]+[a-z0-9]+, $m\$" "$S")
    [ "$n" -ge 2 ] || { echo "FAIL: 'test reg, $m' $n times, want 2 or more"; fail=1; }
done
# Two selects on one condition share the branch: a `test r, 4`, its jump,
# then both true values moved before the label (2026-10-25: perlin 97.0 ->
# 94.8 ms).
pairs=$(awk '{ gsub(/^[ \t]+/, ""); l[NR] = $0 }
    END { for (i = 1; i + 4 <= NR; i++)
            if (l[i] ~ /^test\t[a-z0-9]+, 4$/ && l[i+1] ~ /^j[a-z]+\t\.L_fsel_/ &&
                l[i+2] ~ /^movaps\t/ && l[i+3] ~ /^movaps\t/ && l[i+4] ~ /^\.L_fsel_[0-9]+:$/) n++
          print n + 0 }' "$S")
[ "$pairs" -ge 1 ] || { echo "FAIL: no two selects share a branch in float_select_homes"; fail=1; }
H=${XC_LINUX_HOST:-}
native=$( [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] && echo 1 || echo 0 )
if [ -n "$H" ] || [ $native = 1 ]; then
    [ $native = 1 ] && H=$(uname -n)
    for f in select_mask float_select_homes; do
        "$XC" -q -A x86_64 -O2 -H . -o "$W/$f" tests/fixtures/$f.xc || { echo "FAIL: no x86-64 $f"; fail=1; continue; }
        got=
        if [ $native = 1 ]; then
            got=$("$W/$f")
        else
            scp -q "$W/$f" "$H:/tmp/select-mask.$$" &&
                got=$(ssh "$H" "/tmp/select-mask.$$; rm -f /tmp/select-mask.$$")
        fi
        [ "$got" = "$(cat tests/fixtures/$f.expected.out)" ] || { echo "FAIL: $f on $H printed '$got'"; fail=1; }
    done
fi
[ $fail = 0 ] && echo "select-mask: ok"
exit $fail
