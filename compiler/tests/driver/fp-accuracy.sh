#!/bin/bash
# fp-accuracy.sh — :goal(accuracy) rounds each operation on its own (owner,
# 2026-11-07).
#
# On arm64 a multiply and the add after it fuse only in speed code: a plain
# loop (whose goal is accuracy) keeps fmul and fadd, a loop marked
# :goal(speed) fuses them, and C fuses clang's llvm.fmuladd, as GCC and clang
# do on arm64.
#
#   bash tests/driver/fp-accuracy.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
# arm64 macOS code, which the Mac legs check: a Linux host builds -A arm64
# without the SDK, and the gate ran this there.
[ "$(uname -s)" = Darwin ] || { echo "fp-accuracy: skipped (not macOS)"; exit 0; }
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
xfused() { grep -cE '\bvf(n?m(add|sub))[0-9]+[sp][sd]\b' "$1"; }
fused() { grep -cE '\bf(madd|msub|nmadd|nmsub|mla|mls)\b' "$1"; }
cat > "$W/acc.xc" <<'XC'
#import "Stdio.xc"
float dot(float* a, float* b, u32 n)
{
    float s = 0.0;
    for (u32 i = 0; i < n; i++)
        s = s + a[i] * b[i];
    return s;
}
i32 main(i32 argc, u8** argv)
{
    float* a = new float[1000];
    float* b = new float[1000];
    for (u32 i = 0; i < 1000; i++) { a[i] = (float)i; b[i] = (float)argc; }
    Stdio.printf("%f\n", (double)dot(a, b, (u32)1000));
    return 0;
}
XC
sed 's/for (u32 i = 0; i < n; i++)/for (u32 i = 0; i < n; i++) :goal(speed)/' "$W/acc.xc" > "$W/spd.xc"
cat > "$W/c.c" <<'C'
float dot(const float* a, const float* b, unsigned n)
{
    float s = 0.0f;
    for (unsigned i = 0; i < n; i++)
        s = s + a[i] * b[i];
    return s;
}
C
fail=0
# A program that uses dot, built as one (--par-style=cpu: the loop stays in
# dot, not in a block auto lifts it into); dot must be there to look at, or
# the counts below compare nothing.
"$XC" -q -O2 -A arm64 --par-style=cpu -S -o "$W/acc.s" "$W/acc.xc" || { echo "FAIL build accuracy"; exit 1; }
"$XC" -q -O2 -A arm64 --par-style=cpu -S -o "$W/spd.s" "$W/spd.xc" || { echo "FAIL build speed"; exit 1; }
dotf() { awk '/^_dot:/{p=1;next} p&&/^_[A-Za-z]/{p=0} p' "$1" > "$1.dot"; echo "$1.dot"; }
for f in acc spd; do grep -q '^_dot:' "$W/$f.s" || { echo "FAIL fp-accuracy: no dot in the $f program"; fail=1; }; done
[ "$(fused "$W/acc.s")" = 0 ] || { echo "FAIL an accuracy program fused: $(fused "$W/acc.s")"; fail=1; }
[ "$(fused "$(dotf "$W/spd.s")")" -gt 0 ] || { echo "FAIL a speed loop did not fuse"; fail=1; }
# The C path is the shipped compiler's (xcc-xc), and needs clang.
if command -v clang > /dev/null && [ "${XC##*/}" = xcc-xc ]; then
    "$XC" -q -O2 -A arm64 -S -o "$W/c.s" "$W/c.c" || { echo "FAIL build C"; exit 1; }
    [ "$(fused "$W/c.s")" -gt 0 ] || { echo "FAIL C on arm64 did not fuse"; fail=1; }
    # arm64 Linux too: every arm64 target fuses C, by its CPU, not its name.
    "$XC" -q -O2 -A arm64-linux -S -o "$W/cl.s" "$W/c.c" || { echo "FAIL build C for arm64-linux"; exit 1; }
    [ "$(fused "$W/cl.s")" -gt 0 ] || { echo "FAIL C on arm64 Linux did not fuse"; fail=1; }
    # x86-64 C fuses as clang does (owner, 2026-11-09), where the code has
    # FMA: an -mavx2 build throughout.
    "$XC" -q -O2 -A x86_64 -mavx2 -S -o "$W/cx.s" "$W/c.c" || { echo "FAIL build C for x86_64"; exit 1; }
    [ "$(xfused "$W/cx.s")" -gt 0 ] || { echo "FAIL C on x86-64 (-mavx2) did not fuse"; fail=1; }
    # -fgoal=accuracy never fuses, on any target.
    for t in arm64 arm64-linux; do
        "$XC" -q -O2 -A $t -fgoal=accuracy -S -o "$W/ca.s" "$W/c.c" || { echo "FAIL build C accuracy $t"; exit 1; }
        [ "$(fused "$W/ca.s")" = 0 ] || { echo "FAIL C on $t fused under -fgoal=accuracy"; fail=1; }
    done
    "$XC" -q -O2 -A x86_64 -mavx2 -fgoal=accuracy -S -o "$W/cxa.s" "$W/c.c" || { echo "FAIL build C accuracy x86_64"; exit 1; }
    [ "$(xfused "$W/cxa.s")" = 0 ] || { echo "FAIL C on x86-64 fused under -fgoal=accuracy"; fail=1; }
fi
# x86-64 xc code in an -mavx2 build: a speed loop fuses, an accuracy one does
# not (both compilers).
"$XC" -q -O2 -A x86_64 -mavx2 --par-style=cpu -S -o "$W/xs.s" "$W/spd.xc" || { echo "FAIL build x86 speed"; exit 1; }
"$XC" -q -O2 -A x86_64 -mavx2 --par-style=cpu -S -o "$W/xa.s" "$W/acc.xc" || { echo "FAIL build x86 accuracy"; exit 1; }
[ "$(xfused "$W/xs.s")" -gt 0 ] || { echo "FAIL an x86-64 -mavx2 speed loop did not fuse"; fail=1; }
[ "$(xfused "$W/xa.s")" = 0 ] || { echo "FAIL an x86-64 accuracy program fused: $(xfused "$W/xa.s")"; fail=1; }
[ $fail = 0 ] && echo "fp-accuracy: ok"
exit $fail
