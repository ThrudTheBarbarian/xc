#!/bin/bash
# vex-scalar.sh — a scalar float loop gets an AVX2 clone in VEX form
# (2026-10-25, perlin): only a loop that vectorised kept its avx2 clone, so a
# scalar float loop stayed in SSE's destructive two-operand form, where every
# `op a, b` that must keep a costs a movaps first (74 of the 372 lines of
# perlin's block). The clone now stays, its code takes the VEX forms, and a
# `movaps d, a; op d, b` pair is one `vop d, a, b`: perlin 114 -> 103 ms on
# one thread of a Zen 5. The block has an avx2 clone with fewer copies than
# its SSE base, and the two compilers print the same code.
#
#   bash tests/driver/vex-scalar.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
SRC=../benchmark/par/perlin.xc
[ -f "$SRC" ] || { echo "vex-scalar: no benchmark/par/perlin.xc, skipped"; exit 0; }
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    "$c" -q -A x86_64 -O2 -H . -S -o "$W/$(basename "$c").s" "$SRC" || { echo "FAIL $c: no assembly"; fail=1; }
done
S="$W/$(basename "$XC").s"
fnbody() { awk -v f="$1" '$0 == f":" {p=1; next} p && /^[A-Za-z_][A-Za-z0-9_$]*:$/ {p=0} p' "$S"; }
grep -q '^ParImpl\$0\$run\$avx2:$' "$S" || { echo "FAIL: perlin's block has no avx2 clone"; fail=1; }
base=$(fnbody 'ParImpl$0$run$base' | grep -c movaps)
avx=$(fnbody 'ParImpl$0$run$avx2' | grep -c movaps)
[ "$avx" -lt "$base" ] || { echo "FAIL: the avx2 clone has $avx movaps, the base $base"; fail=1; }
if [ -s "$W/xcc.s" ] && [ -s "$W/xcc-xc.s" ] && ! cmp -s "$W/xcc.s" "$W/xcc-xc.s"; then echo "FAIL: the two compilers' code differs"; fail=1; fi
[ $fail = 0 ] && echo "vex-scalar: ok ($base movaps in SSE, $avx in the avx2 clone)"
exit $fail
