#!/bin/bash
# vector-fma.sh — vectorised loops fuse multiply-adds as scalar code does
# (2026-10-29)
#
# Three float loops, c + a*b, c - a*b and a*b - c, over values whose product
# needs more than a float's precision (a = 1 + 2^-12, so a*a = 1 + 2^-11 +
# 2^-24): fused, the 2^-24 survives the add; split, it rounds away. On arm64,
# which fuses scalar products everywhere, the vectorised loops at -O2 must give
# the scalar -O0 answer, as fmla / fmls / fmls+fneg. On x86-64 the same loops
# under :goal(speed) are vfmadd / vfmsub / vfnmadd in the avx2 and avx512
# copies, and give the fused answer on a host with FMA (XTC_X86_HOST, or here
# on an x86-64 machine).
#
#   [XTC_X86_HOST=<host>] bash tests/driver/vector-fma.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
# $1: the loop head (a plain loop, or one under :goal(speed))
prog() {
    cat <<XC
#import "Stdio.xc"

void fwd(float* o, float* a, float* b, float* c, u32 n) { $1 o[i] = c[i] + a[i] * b[i]; }
void sub1(float* o, float* a, float* b, float* c, u32 n) { $1 o[i] = c[i] - a[i] * b[i]; }
void sub2(float* o, float* a, float* b, float* c, u32 n) { $1 { float t = c[i]; o[i] = a[i] * b[i] - t; } }

i32 main(i32 argc, u8** argv)
{
    u32 n = 1024;
    float* a = new float[n]; float* c = new float[n]; float* o = new float[n];
    for (u32 i = 0; i < n; i = i + 1) { a[i] = 1.000244140625; c[i] = -1.0; }
    fwd(o, a, a, c, n);  Stdio.printf("fwd %.12g %.12g\n", (double)o[0], (double)o[n - 1]);
    for (u32 i = 0; i < n; i = i + 1) c[i] = 1.0;
    sub1(o, a, a, c, n); Stdio.printf("sub1 %.12g %.12g\n", (double)o[0], (double)o[n - 1]);
    sub2(o, a, a, c, n); Stdio.printf("sub2 %.12g %.12g\n", (double)o[0], (double)o[n - 1]);
    return 0;
}
XC
}
FUSED='fwd 0.000488340854645 0.000488340854645
sub1 -0.000488340854645 -0.000488340854645
sub2 0.000488340854645 0.000488340854645'
prog 'for (u32 i = 0; i < n; i = i + 1)' > "$W/v.xc"
prog 'for (u32 i in 0..n) :goal(speed)' > "$W/s.xc"
msg=""
# arm64: -O2's vector loops against -O0's scalar ones.
"$XC" -q -A arm64 -O2 -S -o "$W/v.s" "$W/v.xc" || { echo "FAIL: does not build for arm64"; exit 1; }
for f in 'fmla[[:space:]]+v[0-9]+\.4s' 'fmls[[:space:]]+v[0-9]+\.4s' 'fneg[[:space:]]+v[0-9]+\.4s'; do
    grep -qE "$f" "$W/v.s" || { echo "FAIL vector-fma (arm64): no ${f%%\[*} in the vector loops"; fail=1; }
done
if [ "$(uname -m)" = arm64 ]; then
    "$XC" -q -O0 -o "$W/v0" "$W/v.xc" && "$XC" -q -O2 -o "$W/v2" "$W/v.xc" || { echo "FAIL: does not link"; exit 1; }
    o0=$("$W/v0"); o2=$("$W/v2")
    [ "$o0" = "$FUSED" ] || { echo "FAIL vector-fma (arm64 -O0): the scalar loops do not fuse"; printf '%s\n' "$o0"; fail=1; }
    [ "$o2" = "$o0" ] || { echo "FAIL vector-fma (arm64 -O2): the vector loops round differently from scalar"; printf '%s\n' "$o2"; fail=1; }
    msg="arm64 run"
fi
# x86-64: the speed loops' avx2 and avx512 copies.
"$XC" -q -A x86_64 -static -O2 -S -o "$W/s.s" "$W/s.xc" || { echo "FAIL: does not build for x86-64"; exit 1; }
for f in 'vfmadd(231|213)ps[[:space:]]+ymm' 'vfmsub(231|213)ps[[:space:]]+ymm' 'vfnmadd(231|213)ps[[:space:]]+ymm' \
         'vfmadd(231|213)ps[[:space:]]+zmm' 'vfmsub(231|213)ps[[:space:]]+zmm' 'vfnmadd(231|213)ps[[:space:]]+zmm'; do
    grep -qE "$f" "$W/s.s" || { echo "FAIL vector-fma (x86-64): no '$f' in the speed loops"; fail=1; }
done
run=""
H=${XTC_X86_HOST:-}
SSHO="-o BatchMode=yes -o LogLevel=ERROR"
if [ "$(uname -m)" = x86_64 ] || [ -n "$H" ]; then
    "$XC" -q -A x86_64 -static -O2 -o "$W/s.x" "$W/s.xc" || { echo "FAIL: does not link for x86-64"; exit 1; }
    if [ "$(uname -m)" = x86_64 ]; then
        run=$("$W/s.x")
    else
        scp $SSHO -q "$W/s.x" "$H:vector-fma.bin" || { echo "FAIL: copy to $H"; exit 1; }
        run=$(ssh $SSHO "$H" './vector-fma.bin; rm -f vector-fma.bin')
    fi
    if grep -qw fma /proc/cpuinfo 2>/dev/null || [ -n "$H" ]; then
        [ "$run" = "$FUSED" ] || { echo "FAIL vector-fma (x86-64 run): the speed loops do not fuse"; printf '%s\n' "$run"; fail=1; }
        msg="${msg:+$msg, }x86-64 run"
    fi
fi
[ $fail = 0 ] && echo "vector-fma: ok (code${msg:+, $msg})"
exit $fail
