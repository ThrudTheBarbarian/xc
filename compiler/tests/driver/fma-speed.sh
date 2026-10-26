#!/bin/bash
# fma-speed.sh — x86-64 fuses a float multiply with the add or subtract that
# consumes it ONLY under :goal(speed) (owner, 2026-10-26; GCC and clang fuse by
# default, which put perlin 1.3x ahead of xcc). The same chaotic recurrence
# x = x*x - c twice: in a :goal(speed) loop its avx2 copy is vfmsub231ss, one
# rounding a step; in a plain loop there is none, so the plain answer never
# depends on which copy the CPU runs. Both compilers print the same code. On an
# x86-64 host (or XTC_X86_HOST over ssh) the speed loop's answer under the
# avx2 copy differs from the base copy's (the fused steps diverge, as chaos
# does), and the plain loop's is the same under both.
#
#   [XTC_X86_HOST=<host>] bash tests/driver/fma-speed.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/fma.xc" <<'XC'
#import "Stdio.xc"

float speedy(float x0, float c, u32 n)
{
    float x = x0;
    for (u32 i in 0..n) :goal(speed)
    {
        x = x * x - c;
        x = x * x - c;
        x = x * x - c;
        x = x * x - c;
    }
    return x;
}

float plain(float x0, float c, u32 n)
{
    float x = x0;
    for (u32 i in 0..n)
    {
        x = x * x - c;
        x = x * x - c;
        x = x * x - c;
        x = x * x - c;
    }
    return x;
}

i32 main(void)
{
    Stdio.printf("%.9g %.9g\n", (double)speedy(0.5f, 1.4f, (u32)1000), (double)plain(0.5f, 1.4f, (u32)1000));
    return 0;
}
XC
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    "$c" -q -A x86_64 -O2 -S -o "$W/$(basename "$c").s" "$W/fma.xc" || { echo "FAIL $c: no assembly"; fail=1; }
done
S="$W/$(basename "$XC").s"
fnbody() { awk -v f="$1" '$0 == f":" {p=1; next} p && /^[A-Za-z_][A-Za-z0-9_$]*:$/ {p=0} p' "$S"; }
fused=$(fnbody 'speedy$avx2' | grep -cE 'vfn?m(add|sub)(231|213)ss')
[ "$fused" -ge 4 ] || { echo "FAIL: the speed loop's avx2 copy has $fused fused multiply-adds, want 4"; fail=1; }
plainf=$(grep -cE 'vfn?m(add|sub)' <(fnbody 'plain$avx2'; fnbody 'plain'; fnbody 'plain$base'))
[ "$plainf" = 0 ] || { echo "FAIL: the plain loop has $plainf fused multiply-adds"; fail=1; }
basef=$(fnbody 'speedy$base' | grep -cE 'vfn?m(add|sub)')
[ "$basef" = 0 ] || { echo "FAIL: the speed loop's base (SSE) copy has $basef fused multiply-adds"; fail=1; }
if [ -s "$W/xcc.s" ] && [ -s "$W/xcc-xc.s" ] && ! cmp -s "$W/xcc.s" "$W/xcc-xc.s"; then echo "FAIL: the two compilers' code differs"; fail=1; fi
# The answers, where an x86-64 machine with AVX2 can run them.
run() { :; }
H=${XTC_X86_HOST:-}
if [ "$(uname -m)" = x86_64 ] && [ "$PLAT" = linux ]; then
    "$XC" -q -O2 -o "$W/fma" "$W/fma.xc" || { echo "FAIL: does not build"; exit 1; }
    run() { XC_SIMD=$1 "$W/fma" 2>/dev/null; }
elif [ -n "$H" ]; then
    "$XC" -q -A x86_64 -O2 -o "$W/fma" "$W/fma.xc" || { echo "FAIL: does not build for x86-64"; exit 1; }
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    scp $SSHO -q "$W/fma" "$H:fma-speed.bin" || { echo "FAIL: copy to $H"; exit 1; }
    run() { ssh $SSHO "$H" "XC_SIMD=$1 ./fma-speed.bin 2>/dev/null"; }
fi
a=$(run avx2); b=$(run base)
if [ -n "$a" ] && [ -n "$b" ]; then
    [ "${a#* }" = "${b#* }" ] || { echo "FAIL: the plain loop's answer depends on the copy: '$a' / '$b'"; fail=1; }
    [ "${a%% *}" != "${b%% *}" ] || { echo "FAIL: the speed loop's avx2 answer is the base copy's ($a): not fused"; fail=1; }
    msg="answers: avx2 '$a', base '$b'"
else
    msg="not run (no x86-64 host)"
fi
[ -n "$H" ] && ssh -o BatchMode=yes -o LogLevel=ERROR "$H" 'rm -f fma-speed.bin' 2>/dev/null
[ $fail = 0 ] && echo "fma-speed: ok ($fused fused in the speed loop, none in the plain one; $msg)"
exit $fail
