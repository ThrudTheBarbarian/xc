#!/bin/bash
# float-sr.sh — the exact float strength reductions, and a float select's
# sunk arm in an avx copy (2026-10-28)
#
# On x86-64, which fuses no plain multiply-add: x / 2^k is x * 2^-k when 2^-k is normal,
# x * 2 is x + x and (x * -2) + c is c - (x + x) (arm64 fuses products, so none of it there).
# All exact: the program prints each over zeros of both signs, infinities, a
# NaN and a value whose quotient is subnormal, and must print what the plain
# operations print. Then C perlin's gradient: its avx2 copy must divide by
# nothing (the two / 256.0f are multiplies) and compute `0 - 2v` in place
# (`vsubss d, z, d`), not through xmm0 and back. Runs here and, with
# XTC_X86_HOST, on an x86-64 host.
#
#   [XTC_X86_HOST=<host>] bash tests/driver/float-sr.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/fs.xc" <<'XC'
#import "Stdio.xc"

float half(float x) { return x / 256.0; }
double dq(double x) { return x / 0.25; }
float twice(float x) { return x * 2.0; }
float negtwo(float x, float c) { return x * -2.0 + c; }

i32 main(i32 argc, u8** argv)
{
    float zero = (float)(argc - 1);
    float vals[6];
    vals[0] = zero; vals[1] = -zero; vals[2] = 1.0 / zero; vals[3] = -1.0 / zero; vals[4] = zero / zero; vals[5] = 3.0e-38;
    for (u32 i = 0; i < 6; i = i + 1)
        Stdio.printf("%g %g %g %g %g\n", (double)half(vals[i]), dq((double)vals[i]), (double)twice(vals[i]),
                     (double)negtwo(vals[i], zero), (double)negtwo(vals[i], -zero));
    return 0;
}
XC
WANT='0 0 0 0 -0
-0 -0 -0 0 0
inf inf inf -inf -inf
-inf -inf -inf inf inf
nan nan nan nan nan
1.17188e-40 1.2e-37 6e-38 -6e-38 -6e-38'
check() {  # label, output
    got=$(printf '%s\n' "$2" | sed 's/-nan/nan/g')
    [ "$got" = "$WANT" ] || { echo "FAIL float-sr ($1): the rewritten operations print"; printf '%s\n' "$got"; fail=1; }
}
cat > "$W/g.c" <<'EOF'
#include <stdio.h>
unsigned perm[512];
static float grad(unsigned h, float x, float y)
{
    unsigned g = h & 7;
    float u = g < 4 ? x : y;
    float v = g < 4 ? y : x;
    float a = (g & 1) != 0 ? 0.0f - u : u;
    float b = (g & 2) != 0 ? 0.0f - 2.0f * v : 2.0f * v;
    return a + b;
}
int main(int argc, char** argv)
{
    for (unsigned i = 0; i < 512; i++)
        perm[i] = (i * 2654435761u) >> 3;
    float s = 0.0f;
    for (unsigned i = 0; i < 4000000; i++)
        s += grad(perm[i & 511], (float)(i & 1023) / 256.0f, (float)(i >> 10) / 256.0f);
    printf("%g\n", s);
    return 0;
}
EOF
"$XC" -q -O2 -o "$W/fs" "$W/fs.xc" || { echo "FAIL: does not build"; exit 1; }
check "$(uname -m)" "$("$W/fs")"
msg="$(uname -m)"
if command -v clang >/dev/null 2>&1 && command -v objdump >/dev/null 2>&1; then
    if "$XC" -q -A x86_64 -static -O3 -o "$W/g.x" "$W/g.c"; then
        objdump -d --no-show-raw-insn -M intel "$W/g.x" 2>/dev/null | awk '/<main\$avx2>:/,/^$/' | cut -f2- > "$W/g.dis"
        if [ ! -s "$W/g.dis" ]; then
            echo "FAIL float-sr: no avx2 copy of main to inspect"; fail=1
        else
            ! grep -q 'vdivss' "$W/g.dis" || { echo "FAIL float-sr: the avx2 copy still divides by 256"; fail=1; }
            grep -qE 'vsubss[[:space:]]+(xmm[0-9]+), xmm[0-9]+, \1$' "$W/g.dis" \
                || { echo "FAIL float-sr: no in-place vsubss: the select's 0 - 2v goes through a scratch"; fail=1; }
            msg="$msg, gradient code"
        fi
    else
        echo "FAIL: the C gradient does not build for x86-64"; fail=1
    fi
fi
H=${XTC_X86_HOST:-}
if [ -n "$H" ] && [ "$(uname -m)" != x86_64 ]; then
    "$XC" -q -A x86_64 -O2 -o "$W/fs.x" "$W/fs.xc" || { echo "FAIL: does not build for x86-64"; exit 1; }
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    scp $SSHO -q "$W/fs.x" "$H:float-sr.bin" || { echo "FAIL: copy to $H"; exit 1; }
    check x86_64 "$(ssh $SSHO "$H" './float-sr.bin; rm -f float-sr.bin')"
    msg="$msg and x86_64"
fi
[ $fail = 0 ] && echo "float-sr: ok ($msg)"
exit $fail
