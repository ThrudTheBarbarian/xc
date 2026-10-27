#!/bin/bash
# cvt-dep.sh — an int-to-float conversion zeroes its destination first
# (2026-10-27). cvtsi2ss/sd write only the low element and keep the rest of
# the register, so the conversion waits on whatever last wrote it: in the
# avx2 copy of perlin's block that was a long chain of float maths, and IBS
# samples put the conversions at the top, with 2.3x the base copy's back-end
# stalls and run times swinging 93-122 ms. A `xorps d, d` first (a zero idiom,
# free) breaks the dependency: a steady 91.6 ms. Every cvtsi2 in the base and
# the avx2 copy follows a xorps of its own destination, and the two compilers
# print the same code.
#
#   bash tests/driver/cvt-dep.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/cvt.xc" <<'XC'
#import "Stdio.xc"

float fl(float* a, u32 n)
{
    float s = 0.0f;
    for (u32 i = 0; i < n; i = i + 1)
    {
        i32 k = (i32)a[i];
        u32 u = (u32)k & (u32)255;
        s = s * 0.5f + (a[i] - (float)k) * (float)u;
    }
    return s;
}

i32 main(void)
{
    float* a = new float[64];
    for (u32 i = 0; i < 64; i = i + 1)
        a[i] = (float)i * 1.25f;
    Stdio.printf("%.3f\n", (double)fl(a, (u32)64));
    return 0;
}
XC
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    "$c" -q -A x86_64 -O2 -S -o "$W/$(basename "$c").s" "$W/cvt.xc" || { echo "FAIL $c: no assembly"; fail=1; }
done
S="$W/$(basename "$XC").s"
n=$(grep -cE '^[[:space:]]+v?cvtsi2s[sd]' "$S")
[ "$n" -gt 0 ] || { echo "FAIL cvt-dep: no conversion in the code"; fail=1; }
bad=$(awk '/^[ \t]+v?cvtsi2s[sd]/ { split($0, f, /[\t ,]+/); d = f[3]; if (prev !~ ("^[ \t]+v?xorps[ \t]+" d ",")) print; } { prev = $0 }' "$S")
[ -z "$bad" ] || { echo "FAIL cvt-dep: a conversion without its destination zeroed first:"; printf '%s\n' "$bad" | head -3; fail=1; }
if [ -s "$W/xcc.s" ] && [ -s "$W/xcc-xc.s" ] && ! cmp -s "$W/xcc.s" "$W/xcc-xc.s"; then echo "FAIL cvt-dep: the two compilers' code differs"; fail=1; fi
[ $fail = 0 ] && echo "cvt-dep: ok ($n conversions, each after a xorps of its destination)"
exit $fail
