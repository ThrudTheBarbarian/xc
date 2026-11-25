/* half16lib.c — C functions taking and returning _Float16 and __bf16, built
   by clang, for half16.xc to call and to call back. */
#include <stdarg.h>

_Float16 h_add(_Float16 a, _Float16 b) { return a + b; }
__bf16 bf_id(__bf16 x) { return x; }
_Float16 h_neg(_Float16 x) { return -x; }

/* Eleven halves and an int: on arm64 the ninth half on goes on the stack
   (Darwin packs them in two bytes), on x86-64 the ninth, on win64 the fifth. */
_Float16 h_many(_Float16 a, _Float16 b, _Float16 c, _Float16 d, _Float16 e, _Float16 f,
                _Float16 g, _Float16 h, _Float16 i, _Float16 j, int k, _Float16 l)
{
    return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + i * 9 + j * 10 + k + l * 12;
}

double h_mixed(float f, _Float16 h, double d, __bf16 b, int i)
{
    return f * 1000.0 + (double)h * 100.0 + d * 10.0 + (double)b + i;
}

typedef _Float16 (*hcb)(_Float16, _Float16, _Float16, _Float16, _Float16, _Float16,
                        _Float16, _Float16, _Float16, _Float16, int, _Float16);
_Float16 h_callback(hcb f) { return f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12); }

typedef __bf16 (*bcb)(__bf16);
float bf_callback(bcb f, float v) { return (float)f((__bf16)v) + 0.5f; }

/* Variadic: a half reaches it promoted to double. */
double h_vsum(int n, ...)
{
    va_list ap;
    va_start(ap, n);
    double s = 0;
    for (int i = 0; i < n; i++)
        s += va_arg(ap, double);
    va_end(ap);
    return s;
}
