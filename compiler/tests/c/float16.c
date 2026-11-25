#include <stdarg.h>
#include <stdio.h>

/* C's _Float16 and __bf16 through xcc: arithmetic rounded per operation,
   conversions, comparisons, the C calling convention against functions
   clang compiles (a variadic definition is clang's), and a loop over
   _Float16 arrays that becomes a par block. */

#define N 4096
_Float16 xa[N], xb[N], xc[N];

__attribute__((noinline)) _Float16 h_add(_Float16 a, _Float16 b) { return a + b; }
__attribute__((noinline)) _Float16 h_fma(_Float16 a, _Float16 b, _Float16 c) { return a * b + c; }
__attribute__((noinline)) __bf16 bf_mul(__bf16 a, __bf16 b) { return a * b; }
__attribute__((noinline)) __bf16 bf_id(__bf16 x) { return x; }
__attribute__((noinline)) int h_lt(_Float16 a, _Float16 b) { return a < b; }
__attribute__((noinline)) _Float16 h_neg(_Float16 a) { return -a; }
__attribute__((noinline)) _Float16 h_from_int(int i) { return (_Float16)i; }
__attribute__((noinline)) _Float16 h_from_uint(unsigned u) { return (_Float16)u; }
__attribute__((noinline)) _Float16 h_from_ll(long long v) { return (_Float16)v; }
__attribute__((noinline)) int h_to_int(_Float16 h) { return (int)h; }
__attribute__((noinline)) unsigned h_to_uint(_Float16 h) { return (unsigned)h; }
__attribute__((noinline)) _Float16 h_from_double(double d) { return (_Float16)d; }
__attribute__((noinline)) __bf16 bf_from_float(float f) { return (__bf16)f; }
__attribute__((noinline)) double bf_to_double(__bf16 b) { return (double)b; }
__attribute__((noinline)) _Float16 h_bits(unsigned short u)
{
    _Float16 h;
    __builtin_memcpy(&h, &u, 2);
    return h;
}

struct hpair { _Float16 x; __bf16 y; int n; };
__attribute__((noinline)) float pair_sum(struct hpair *p) { return (float)p->x + (float)p->y + p->n; }

/* Called by clang's code below: eleven halves and an int, so the ninth on
   go on the stack. */
__attribute__((noinline)) _Float16 xc_many(_Float16 a, _Float16 b, _Float16 c, _Float16 d, _Float16 e,
                                           _Float16 f, _Float16 g, _Float16 h, _Float16 i, _Float16 j,
                                           int k, _Float16 l)
{
    return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + i * 9 + j * 10 + k + l * 12;
}

/* Variadic, so clang compiles it: called with halves from xcc's code, and
   calling xcc's xc_many. */
_Float16 cl_many(_Float16 a, _Float16 b, _Float16 c, _Float16 d, _Float16 e, _Float16 f,
                 _Float16 g, _Float16 h, _Float16 i, _Float16 j, int k, _Float16 l, ...)
{
    va_list ap;
    va_start(ap, l);
    double extra = va_arg(ap, double);
    va_end(ap);
    _Float16 r = xc_many(a, b, c, d, e, f, g, h, i, j, k, l);
    return r + (_Float16)extra;
}

__attribute__((noinline)) void fill(void)
{
    for (int i = 0; i < N; i++)
    {
        xa[i] = (_Float16)(i % 61) * (_Float16)0.125;
        xb[i] = (_Float16)(i % 17) - (_Float16)8;
        xc[i] = (_Float16)0.5;
    }
}

__attribute__((noinline)) void madd(void)
{
    for (int i = 0; i < N; i++)
        xc[i] = xa[i] * xb[i] + xc[i];
}

int main(void)
{
    _Float16 a = 1.0f16, b = 0.0004887f16;
    printf("add %a %a\n", (double)h_add(a, b), (double)h_add((_Float16)65504, (_Float16)32));
    printf("fma %a\n", (double)h_fma((_Float16)1.5, (_Float16)3.25, (_Float16)0.001));
    printf("bf %a %a\n", (double)bf_mul((__bf16)3.140625f, (__bf16)2.5f), (double)bf_id((__bf16)-0.0f));
    printf("lt %d %d %d\n", h_lt(a, b), h_lt(b, a), h_lt(h_bits(0x7e00), a));
    printf("neg %a %a\n", (double)h_neg(a), (double)h_neg(h_bits(0)));
    printf("int %a %a %a %a\n", (double)h_from_int(2049), (double)h_from_int(-70000),
           (double)h_from_uint(65519u), (double)h_from_ll(4097LL));
    printf("toint %d %u %d\n", h_to_int((_Float16)-2.75), h_to_uint((_Float16)65504), h_to_int(h_bits(0x0001)));
    printf("dbl %a %a %a\n", (double)h_from_double(0.1), (double)h_from_double(5.960464477539063e-08),
           (double)h_from_double(2.980232238769531e-08));
    printf("bfconv %a %a\n", (double)bf_from_float(1.00390625f), bf_to_double((__bf16)3.0e38f));
    printf("sub %a %a\n", (double)h_bits(0x0001), (double)h_bits(0x03ff));
    struct hpair p = { (_Float16)1.5, (__bf16)2.25f, 3 };
    printf("pair %g\n", pair_sum(&p));
    printf("variadic %g %g\n", (double)a, (double)(a + b));
    _Float16 r = cl_many(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0.5);
    printf("many %g %g\n", (double)r, (double)xc_many(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12));
    fill();
    madd();
    double sum = 0;
    for (int i = 0; i < N; i++)
        sum += (double)xc[i] * (double)(i % 7 + 1);
    printf("madd %.17g %a %a\n", sum, (double)xc[123], (double)xc[N - 1]);
    return 0;
}
