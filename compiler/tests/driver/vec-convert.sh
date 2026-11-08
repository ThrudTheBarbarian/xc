#!/bin/bash
# vec-convert.sh — map loops that convert between 32-bit integers and floats
# vectorise (#27), and give the scalar loop's answers.
#
# The map vectoriser took one lane type a loop, so `o[i] = (float)a[i]` and
# `o[i] = (i32)f[i]` stayed scalar. Now I32/U32 <-> F32 conversions vectorise
# on arm64 and x86-64: signed through scvtf/fcvtzs (cvtdq2ps/cvttps2dq), the
# unsigned forms built from them, and xc's rule that an out-of-range float
# converts to 0 (spec 3.1) kept by a lane mask. Checked: each direction over
# the edges (both sides of each range limit, -0.5, NaN and the infinities,
# u32 values above 2^31, values that round) prints at -O3 what the scalar
# loop prints at -O0, with both compilers; each loop is vector code; and an
# x86-64 build gives the same where a Linux host can run it.
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
REF=${REF:-bin/$PLAT/xcc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/c.xc" <<'XC'
#import "Stdio.xc"
#define N 67
void sitofp(float* o, i32* a, u32 n) { for (u32 i = (u32)0; i < n; i++) o[i] = (float)a[i] * 0.5; }
void uitofp(float* o, u32* a, u32 n) { for (u32 i = (u32)0; i < n; i++) o[i] = (float)a[i]; }
void fptosi(i32* o, float* a, u32 n) { for (u32 i = (u32)0; i < n; i++) o[i] = (i32)a[i]; }
void fptoui(u32* o, float* a, u32 n) { for (u32 i = (u32)0; i < n; i++) o[i] = (u32)a[i] + (u32)1; }
i32 main(i32 argc, u8** argv)
    {
    float zero = (float)(argc - 1);
    float e[24];
    e[0] = -3.0e9; e[1] = -2147483904.0; e[2] = -2147483648.0; e[3] = -2147483520.0;
    e[4] = -1.5; e[5] = -1.0; e[6] = -0.99; e[7] = -0.5; e[8] = 0.0 - zero; e[9] = 0.5;
    e[10] = 1.99; e[11] = 2147483520.0; e[12] = 2147483648.0; e[13] = 2147483904.0;
    e[14] = 4294967040.0; e[15] = 4294967296.0; e[16] = 5.0e9; e[17] = zero / zero;
    e[18] = 1.0 / zero; e[19] = -1.0 / zero; e[20] = 123.75; e[21] = 16777217.0;
    e[22] = 3000000000.0; e[23] = -7.25;
    i32 si[8]; si[0] = (i32)-2147483647 - (i32)1; si[1] = (i32)2147483647; si[2] = (i32)16777217;
    si[3] = (i32)-16777217; si[4] = (i32)0; si[5] = (i32)-1; si[6] = (i32)33554435; si[7] = (i32)123456789;
    u32 ui[8]; ui[0] = (u32)$FFFFFFFF; ui[1] = (u32)$80000001; ui[2] = (u32)16777217; ui[3] = (u32)$80000080;
    ui[4] = (u32)0; ui[5] = (u32)$7FFFFFFF; ui[6] = (u32)$FFFFFF7F; ui[7] = (u32)$C0000040;
    float* f = new float[N]; i32* a = new i32[N]; u32* u = new u32[N];
    float* of = new float[N]; i32* oi = new i32[N]; u32* ou = new u32[N];
    for (u32 i = (u32)0; i < (u32)N; i++)
        {
        f[i] = e[i % (u32)24];
        a[i] = si[i % (u32)8] + (i32)(i / (u32)8);
        u[i] = ui[i % (u32)8] - i / (u32)8;
        }
    fptosi(oi, f, (u32)N);
    fptoui(ou, f, (u32)N);
    for (u32 i = (u32)0; i < (u32)N; i++) Stdio.printf("%d %u\n", oi[i], ou[i]);
    sitofp(of, a, (u32)N);
    for (u32 i = (u32)0; i < (u32)N; i++) Stdio.printf("%.1f\n", (double)of[i]);
    uitofp(of, u, (u32)N);
    for (u32 i = (u32)0; i < (u32)N; i++) Stdio.printf("%.1f\n", (double)of[i]);
    return 0;
    }
XC
# What each converting loop's body must hold once vectorised.
want_arm() { case $1 in sitofp) echo 'scvtf.*\.4s' ;; uitofp) echo 'scvtf.*\.4s' ;; fptosi) echo 'fcvtzs.*\.4s' ;; fptoui) echo 'fcvtzs.*\.4s' ;; esac; }
for c in "$XC" "$REF"; do
    n=$(basename "$c")
    "$c" -q -H . -O0 --par-style=cpu -o "$W/c0" "$W/c.xc" > "$W/e" 2>&1 || { echo "FAIL vec-convert: $n -O0 does not build"; fail=1; continue; }
    "$c" -q -H . -O3 --par-style=cpu -o "$W/c3" "$W/c.xc" > "$W/e" 2>&1 || { echo "FAIL vec-convert: $n -O3 does not build"; head -3 "$W/e"; fail=1; continue; }
    if [ "$PLAT" = osx ]; then
        "$W/c0" > "$W/want" 2>&1; "$W/c3" > "$W/got" 2>&1
        cmp -s "$W/want" "$W/got" || { echo "FAIL vec-convert: $n arm64 -O3 differs from -O0:"; diff "$W/want" "$W/got" | head -6; fail=1; }
    fi
    "$c" -q -H . -O3 -A arm64 --par-style=cpu -S -o "$W/c.s" "$W/c.xc" > "$W/e" 2>&1 || { echo "FAIL vec-convert: $n: -S"; fail=1; continue; }
    for fn in sitofp uitofp fptosi fptoui; do
        awk -v f="_$fn:" '$0==f{p=1;next} p&&/^_[A-Za-z]/{p=0} p' "$W/c.s" | grep -qE "$(want_arm $fn)" \
            || { echo "FAIL vec-convert: $n: $fn is not vectorised on arm64"; fail=1; }
    done
    "$c" -q -H . -O3 -A x86_64 -static --par-style=cpu -S -o "$W/x.s" "$W/c.xc" > "$W/e" 2>&1 || { echo "FAIL vec-convert: $n x86_64 -S"; fail=1; continue; }
    grep -qE 'cvttps2dq' "$W/x.s" && grep -qE 'cvtdq2ps' "$W/x.s" || { echo "FAIL vec-convert: $n: no lane conversions on x86-64"; fail=1; }
    if [ "$PLAT" = linux ]; then
        "$c" -q -H . -O0 -A x86_64 -static --par-style=cpu -o "$W/x0" "$W/c.xc" > "$W/e" 2>&1 \
            && "$c" -q -H . -O3 -A x86_64 -static --par-style=cpu -o "$W/x3" "$W/c.xc" > "$W/e" 2>&1 \
            || { echo "FAIL vec-convert: $n x86_64 does not build"; fail=1; continue; }
        "$W/x0" > "$W/want" 2>&1; "$W/x3" > "$W/got" 2>&1
        cmp -s "$W/want" "$W/got" || { echo "FAIL vec-convert: $n x86_64 -O3 differs from -O0:"; diff "$W/want" "$W/got" | head -6; fail=1; }
    fi
done
[ $fail -eq 0 ] && echo "--- vec-convert: integer/float conversion loops vectorise and match the scalar loop ---"
exit $fail
