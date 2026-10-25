#!/bin/bash
# md5-interleave.sh — an AVX-512 loop with a big body interleaves two lane
# groups (2026-10-25, md5 step 3): the optimiser sized x86's vector pool at 14
# for every width, so MD5's 64 rounds stayed one serial chain at AVX-512; with
# zmm16-31 (30 registers) the unroller interleaves two groups, as clang does.
# One thread on a Zen 5 host: md5 394 -> 229 ms (clang -O3 -march=native 212),
# md5_mask 315 -> 189 (176).
#
# The AVX-512 form of md5's hash has two groups' rotates (128 vprold, 64 for
# one), the two compilers print the same code, and on an AVX-512 Linux host
# the program gives its checksum.
#
#   bash tests/driver/md5-interleave.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
SRC=../apps/hashcat/md5.xc
[ -f "$SRC" ] || { echo "md5-interleave: no apps/hashcat, skipped"; exit 0; }
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    "$c" -q -A x86_64 -O2 -H . -S -o "$W/$(basename "$c").s" "$SRC" || { echo "FAIL $c: no assembly"; fail=1; continue; }
done
n=$(grep -c vprold "$W/$(basename "$XC").s" 2>/dev/null)
[ "${n:-0}" -ge 128 ] || { echo "FAIL: md5 at AVX-512 is one lane group ($n vprold, want 128)"; fail=1; }
if [ -s "$W/xcc.s" ] && [ -s "$W/xcc-xc.s" ] && ! cmp -s "$W/xcc.s" "$W/xcc-xc.s"; then echo "FAIL: the two compilers' code differs"; fail=1; fi
if [ "$(uname -s)" = Linux ] && grep -q avx512f /proc/cpuinfo 2> /dev/null; then
    "$XC" -q -A x86_64 -O2 -H . -o "$W/md5" "$SRC" || { echo "FAIL: build"; fail=1; }
    got=$(XC_PAR=cpu XC_PAR_THREADS=1 "$W/md5" 2>/dev/null | cut -d' ' -f1)
    [ "$got" = 2573682417 ] || { echo "FAIL: md5 gives $got, want 2573682417"; fail=1; }
fi
[ $fail = 0 ] && echo "md5-interleave: ok"
exit $fail
