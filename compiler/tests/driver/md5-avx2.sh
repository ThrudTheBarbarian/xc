#!/bin/bash
# md5-avx2.sh — an AVX2 loop gets the vector combines and the constant table
# that an AVX-512 loop has (issue 197). x86's vec-combine ran only on 64-byte
# functions, so an AVX2 copy rebuilt each of MD5's round constants every
# iteration (mov, mov, mov, vpxor, movd, vpbroadcastd) and wrote each select
# as vpand, vpcmpeqd, vpxor, vpand, vpor. Now the constants are one
# vpbroadcastd from __xtv_kpool_* each and a select is vpandn, vpand, vpor.
# One thread, AVX2 copy: md5 766 -> 647 ms (clang 21 -O3: 619), md5_mask
# 621 -> 527 (497).
#
# The AVX2 form of md5's hash reads its constants from the table and selects
# with vpandn, the two compilers print the same code, and on an AVX2 Linux
# host the program gives its checksum.
#
#   bash tests/driver/md5-avx2.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
SRC=../apps/hashcat/md5.xc
[ -f "$SRC" ] || { echo "md5-avx2: no apps/hashcat, skipped"; exit 0; }
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    "$c" -q -A x86_64 -O2 -mavx2 -H . -S -o "$W/$(basename "$c").s" "$SRC" || { echo "FAIL $c: no assembly"; fail=1; continue; }
done
S="$W/$(basename "$XC").s"
n=$(grep -c 'vpbroadcastd.*ptr' "$S" 2>/dev/null)
[ "${n:-0}" -ge 64 ] || { echo "FAIL: md5 at AVX2 broadcasts $n constants from memory, want 64 or more"; fail=1; }
n=$(grep -c vpandn "$S" 2>/dev/null)
[ "${n:-0}" -ge 24 ] || { echo "FAIL: md5 at AVX2 has $n vpandn, want 24 or more (F and G selects)"; fail=1; }
if [ -s "$W/xcc.s" ] && [ -s "$W/xcc-xc.s" ] && ! cmp -s "$W/xcc.s" "$W/xcc-xc.s"; then echo "FAIL: the two compilers' code differs"; fail=1; fi
if [ "$(uname -s)" = Linux ] && grep -q avx2 /proc/cpuinfo 2> /dev/null; then
    "$XC" -q -A x86_64 -O2 -H . -o "$W/md5" "$SRC" || { echo "FAIL: build"; fail=1; }
    got=$(XC_SIMD=avx2 XC_PAR=cpu XC_PAR_THREADS=1 "$W/md5" 2>/dev/null | cut -d' ' -f1)
    [ "$got" = 2573682417 ] || { echo "FAIL: md5 gives $got, want 2573682417"; fail=1; }
fi
[ $fail = 0 ] && echo "md5-avx2: ok"
exit $fail
