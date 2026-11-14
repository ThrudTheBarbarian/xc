#!/bin/bash
# x86-flags.sh — a compare against zero after arithmetic that set the flags
# goes (#41). sort_small's insertion loop tested its exit with
# `sub r, 1 ; cmp r, 0 ; jbe`; the sub already set ZF from r, so it is now
# `sub r, 1 ; je`. Only conditions on ZF and SF qualify (jbe/ja against zero
# become je/jne); jg and the like stay, as the arithmetic can set OF where the
# compare clears it. sort_small, one thread on Zen 5: 838 -> 796 ms.
#
# sort_small has no `sub`, `cmp 0`, `jbe` run left,
# the two compilers print the same code, and on an x86-64 Linux host
# sort_small gives its checksum.
#
#   bash tests/driver/x86-flags.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
D=../benchmark/src
[ -f "$D/sort_small.xc" ] || { echo "x86-flags: no benchmark sources, skipped"; exit 0; }
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    "$c" -q -A x86_64 -O2 -H . -I "$D" -S -o "$W/$(basename "$c").s" "$D/sort_small.xc" || { echo "FAIL $c: no assembly"; fail=1; }
done
if [ -s "$W/xcc.s" ] && [ -s "$W/xcc-xc.s" ] && ! cmp -s "$W/xcc.s" "$W/xcc-xc.s"; then echo "FAIL: the two compilers' code differs"; fail=1; fi
S="$W/$(basename "$XC").s"
n=$(awk 'a ~ /^\tsub\t/ && b ~ /^\tcmp\t[a-z0-9]+, 0$/ && $0 ~ /^\tjbe\t/ {k++} {a = b; b = $0} END {print k + 0}' "$S")
[ "$n" = 0 ] || { echo "FAIL: $n sub/cmp 0/jbe runs left"; fail=1; }
n=$(grep -c $'^\tje\t' "$S")
[ "$n" -gt 0 ] || { echo "FAIL: no je in sort_small"; fail=1; }
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; then
    "$XC" -q -A x86_64 -O2 -H . -I "$D" -o "$W/sort_small" "$D/sort_small.xc" || { echo "FAIL: build"; fail=1; }
    got=$(XC_PAR=cpu XC_PAR_THREADS=1 "$W/sort_small" x 2>/dev/null | cut -d' ' -f1)
    [ "$got" = 615912388 ] || { echo "FAIL: sort_small gives $got, want 615912388"; fail=1; }
fi
[ $fail = 0 ] && echo "x86-flags: ok"
exit $fail
