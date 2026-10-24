#!/bin/bash
# zmm-high.sh — AVX-512 code uses zmm16-31 (2026-10-24, md5 step 2): a
# function whose vectors are all 64 bytes takes registers past 15, and no
# register past 15 is ever named as xmm or ymm (EVEX has those forms; the
# assemblers do not, and a reduction folds through them, so a class it reads
# stays below 16). Both compilers, the same assembly; on an AVX-512 host the
# program runs and gives its answer.
#
#   bash tests/driver/zmm-high.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
# Twenty live 64-byte vectors: more than the sixteen low registers hold.
cat > "$W/wide.xc" <<'XC'
#import "Stdio.xc"
#define N 4096
u32 a[N];
u32 b[N];
i32 main(void)
    {
    for (u32 i in 0..N) { a[i] = i * (u32)2654435761; b[i] = i ^ (u32)40503; }
    for (u32 r in 0..4)
        for (u32 i in 0..N)
            {
            u32 x = a[i];
            u32 y = b[i];
            u32 t0 = x + y; u32 t1 = x ^ y; u32 t2 = x * (u32)3 + y; u32 t3 = (x >> 3) + (y << 5);
            u32 t4 = t0 ^ t3; u32 t5 = t1 + t2; u32 t6 = t0 * t1; u32 t7 = t2 ^ (t3 >> 7);
            u32 t8 = t4 + t5 + (u32)17; u32 t9 = t6 ^ t7 ^ (u32)99;
            a[i] = t0 + t1 + t2 + t3 + t4 + t5 + t6 + t7 + t8 + t9;
            }
    u32 s = (u32)0;
    for (u32 i in 0..N) s = s ^ a[i];
    Stdio.printf("%u\n", s);
    return 0;
    }
XC
REF=bin/osx/xcc; XC=bin/osx/xcc-xc
[ "$(uname -s)" = Linux ] && { REF=bin/linux/xcc; XC=bin/linux/xcc-xc; }
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    "$c" -q -A x86_64 -O2 -mavx512 -H . -S -o "$W/$(basename "$c").s" "$W/wide.xc" \
        || { echo "FAIL $c: no assembly"; fail=1; continue; }
    s="$W/$(basename "$c").s"
    grep -qE '\bzmm(1[6-9]|2[0-9]|3[01])\b' "$s" || { echo "FAIL $c: no zmm16-31 in AVX-512 code"; fail=1; }
    if grep -qE '\b[xy]mm(1[6-9]|2[0-9]|3[01])\b' "$s"; then
        echo "FAIL $c: a register past 15 named as xmm/ymm:"; grep -m3 -E '\b[xy]mm(1[6-9]|2[0-9]|3[01])\b' "$s"; fail=1
    fi
done
if [ -x "$REF" ] && [ -x "$XC" ] && ! cmp -s "$W/$(basename "$REF").s" "$W/$(basename "$XC").s"; then
    echo "FAIL: the two compilers' AVX-512 assembly differs"; fail=1
fi
if grep -q avx512f /proc/cpuinfo 2> /dev/null; then
    "$XC" -q -A x86_64 -O2 -mavx512 -H . -o "$W/wide" "$W/wide.xc" && "$XC" -q -A x86_64 -O0 -H . -o "$W/wide0" "$W/wide.xc" \
        || { echo "FAIL: build"; fail=1; }
    [ "$("$W/wide")" = "$("$W/wide0")" ] || { echo "FAIL: AVX-512 answer differs from -O0's"; fail=1; }
fi
[ $fail = 0 ] && echo "zmm-high: ok"
exit $fail
