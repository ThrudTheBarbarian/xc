#!/bin/bash
# cfloatstack.sh — float and double arguments past xmm7 on the C path (#313).
# Under x86-64 SysV a float argument past the eight SSE registers goes on the
# stack in source order, interleaved with integers past r9. main, which xcc
# builds, calls functions xcc builds with 9 to 12 doubles, 10 floats, and
# integers and doubles that both overflow, and passes 11 doubles to printf.
# Functions left to clang (a struct parameter, a label table, an indirect
# call) call into xcc's nine and are called from main, so the stack layout
# must match clang's in each direction. The output must equal clang's own
# build, at -O0 and -O2. Skipped without clang. Self-hosted compiler only.
#
#   bash tests/par/cfloatstack.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version > /dev/null 2>&1; then
    echo "--- cfloatstack: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/fs.c" <<'C'
#include <stdio.h>

struct D2 { double x, y; };

__attribute__((noinline)) double nine(double a, double b, double c, double d, double e,
                                      double f, double g, double h, double k)
{
    return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + k * 9;
}

__attribute__((noinline)) double twelve(double a, double b, double c, double d, double e, double f,
                                        double g, double h, double k, double l, double m, double n)
{
    return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + k * 9 + l * 10 + m * 11 + n * 12;
}

__attribute__((noinline)) float tenf(float a, float b, float c, float d, float e,
                                     float f, float g, float h, float k, float l)
{
    return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + k * 9 + l * 10;
}

__attribute__((noinline)) double interleaved(long n1, double d1, long n2, double d2, long n3, double d3,
                                             long n4, double d4, long n5, double d5, long n6, double d6,
                                             long n7, double d7, double d8, double d9, long n8, double d10)
{
    double is = n1 + n2 * 2 + n3 * 3 + n4 * 4 + n5 * 5 + n6 * 6 + n7 * 7 + n8 * 8;
    double ds = d1 + d2 * 2 + d3 * 3 + d4 * 4 + d5 * 5 + d6 * 6 + d7 * 7 + d8 * 8 + d9 * 9 + d10 * 10;
    return is * 1000 + ds;
}

/* Seven doubles leave one SSE register: the struct needs two, so it goes
   whole on the stack, and the double after it takes xmm7. */
__attribute__((noinline)) double pair(double a, double b, double c, double d, double e, double f,
                                      double g, struct D2 p, double h)
{
    return a + b + c + d + e + f + g + p.x * 100 + p.y * 1000 + h * 10000;
}

/* Left to clang (the label table), and calling back into nine. */
double viaClang(int sel, double a, double b, double c, double d, double e, double f,
                double g, double h, double k, double l)
{
    static void *tab[] = { &&one, &&two };
    goto *tab[sel & 1];
one:
    return nine(a, b, c, d, e, f, g, h, k) + l * 100;
two:
    return nine(b, c, d, e, f, g, h, k, l) - a;
}

/* The struct's caller is left to clang on some targets, so main is not. */
__attribute__((noinline)) double callPair(double v)
{
    struct D2 q = { 3 * v, 4 * v };
    return pair(v, 2, 3, 4, 5, 6, 7, q, 9 * v);
}

typedef double (*nine_t)(double, double, double, double, double, double, double, double, double);

/* An indirect call is left to clang too: clang calls nine, which xcc built. */
__attribute__((noinline)) double callPtr(nine_t p, double v)
{
    return p(2 * v, 2, 2, 2, 2, 2, 2, 2, 2 * v);
}

int main(int argc, char **argv)
{
    double v = argc;  /* 1.0, not a constant clang can fold */
    nine_t p = argc > 5 ? 0 : nine;
    printf("%f\n", nine(v, v, v, v, v, v, v, v, v));
    printf("%f\n", nine(v, 2 * v, 3 * v, 4 * v, 5 * v, 6 * v, 7 * v, 8 * v, 9 * v));
    printf("%f\n", twelve(v, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 * v));
    printf("%f\n", (double)tenf((float)v, 2, 3, 4, 5, 6, 7, 8, 9, 10 * (float)v));
    printf("%f\n", interleaved(argc, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6, 6.5, 7, 7.5, 8.5, 9.5, 8 * argc, 10.5 * v));
    printf("%f\n", callPair(v));
    printf("%f\n", callPtr(p, v));
    printf("%f %f\n", viaClang(0, v, 2, 3, 4, 5, 6, 7, 8, 9, 10 * v), viaClang(1, v, 2, 3, 4, 5, 6, 7, 8, 9, 10 * v));
    printf("%f %f %f %f %f %f %f %f %f %f %f\n", v, 2 * v, 3 * v, 4 * v, 5 * v, 6 * v, 7 * v, 8 * v, 9 * v, 10 * v, 11 * v);
    printf("%d %f %d %f %f %f %f %f %f %f %f %f %ld\n", argc, v, 2, 2 * v, 3 * v, 4 * v, 5 * v, 6 * v, 7 * v, 8 * v, 9 * v, 10 * v, 99L * argc);
    return 0;
}
C
clang -O2 -o "$W/fs.ref" "$W/fs.c" 2>/dev/null || { echo "FAIL cfloatstack: clang cannot build fs.c"; exit 1; }
want=$("$W/fs.ref")
for o in 0 2; do
    XC_C_TRACE=1 "$XC" -q -O$o -o "$W/fs$o" "$W/fs.c" > "$W/fs$o.b" 2>&1 \
        || { echo "FAIL cfloatstack: fs.c does not build at -O$o"; head -3 "$W/fs$o.b"; fail=1; continue; }
    grep -q 'left to clang: @viaClang' "$W/fs$o.b" || echo "note cfloatstack: viaClang was not left to clang at -O$o; the case covers less"
    grep -q 'left to clang: @main' "$W/fs$o.b" && echo "note cfloatstack: main was left to clang at -O$o; the case covers less"
    got=$("$W/fs$o")
    if [ "$got" != "$want" ]; then
        echo "FAIL cfloatstack: -O$o differs from clang's build:"
        diff <(echo "$want") <(echo "$got") | head -20
        fail=1
    fi
done
[ $fail = 0 ] && echo "--- cfloatstack: pass ---" || echo "--- cfloatstack: FAIL ---"
exit $fail
