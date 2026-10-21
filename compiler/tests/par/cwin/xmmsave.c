/* xmmsave: Win64 keeps xmm6-xmm15 for the caller. keep() is variadic, so
   clang compiles it, and clang holds its eight doubles in xmm6 and up across
   each call to work(), which xcc compiles and which has enough floats live to
   home them in xmm8 and up. Without xcc saving those registers keep()'s
   values come back changed. Every value is a small integer, exact in any
   order of evaluation. */
#include <stdio.h>
#include <stdarg.h>
double work(double x)
{
    double a = x + 1, b = x + 2, c = x + 3, d = x + 4, e = x + 5, f = x + 6;
    double g = x + 7, h = x + 8, i = x + 9, j = x + 10, k = x + 11, l = x + 12;
    for (int n = 0; n < 6; n++) {
        double t = a;
        a = b - c + d; b = c - d + e; c = d - e + f; d = e - f + g; e = f - g + h; f = g - h + i;
        g = h - i + j; h = i - j + k; i = j - k + l; j = k - l + t; k = l - t + b; l = t - b + c;
    }
    return a + b + c + d + e + f + g + h + i + j + k + l;
}
double keep(int count, ...)
{
    va_list ap;
    va_start(ap, count);
    double v0 = va_arg(ap, double), v1 = va_arg(ap, double), v2 = va_arg(ap, double), v3 = va_arg(ap, double);
    double v4 = va_arg(ap, double), v5 = va_arg(ap, double), v6 = va_arg(ap, double), v7 = va_arg(ap, double);
    va_end(ap);
    // All eight change every round from work()'s result, so all eight are
    // live across every call: clang keeps them in xmm6 and up.
    for (int r = 0; r < count; r++) {
        double w = work((double)r);
        v0 = v0 + w; v1 = v1 - v0; v2 = v2 + v1; v3 = v3 - v2;
        v4 = v4 + v3; v5 = v5 - v4; v6 = v6 + v5; v7 = v7 - v6;
    }
    return v0 + v1 * 2 + v2 * 3 + v3 * 5 + v4 * 7 + v5 * 11 + v6 * 13 + v7 * 17;
}
int main(void)
{
    double r = keep(10, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
    printf("%.1f\n", r);
    return 0;
}
