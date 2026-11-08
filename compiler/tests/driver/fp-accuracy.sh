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
fi
[ $fail = 0 ] && echo "fp-accuracy: ok"
exit $fail
