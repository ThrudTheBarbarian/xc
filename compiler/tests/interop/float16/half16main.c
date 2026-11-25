/* half16main.c — half16.xc's calls made from C, built by clang: what it
   prints is what half16.xc must print. */
#include <stdio.h>

_Float16 h_add(_Float16 a, _Float16 b);
__bf16 bf_id(__bf16 x);
_Float16 h_neg(_Float16 x);
_Float16 h_many(_Float16 a, _Float16 b, _Float16 c, _Float16 d, _Float16 e, _Float16 f,
                _Float16 g, _Float16 h, _Float16 i, _Float16 j, int k, _Float16 l);
double h_mixed(float f, _Float16 h, double d, __bf16 b, int i);
typedef _Float16 (*hcb)(_Float16, _Float16, _Float16, _Float16, _Float16, _Float16,
                        _Float16, _Float16, _Float16, _Float16, int, _Float16);
_Float16 h_callback(hcb f);
typedef __bf16 (*bcb)(__bf16);
float bf_callback(bcb f, float v);
double h_vsum(int n, ...);

static _Float16 c_many(_Float16 a, _Float16 b, _Float16 c, _Float16 d, _Float16 e, _Float16 f,
                       _Float16 g, _Float16 h, _Float16 i, _Float16 j, int k, _Float16 l)
{
    return a - b + c - d + e - f + g - h + i * 3 - j * 2 + (_Float16)k + l / 4;
}
static __bf16 c_bf(__bf16 x) { return x * (__bf16)3.0f; }

int main(void)
{
    _Float16 a = 1.5f16, b = 0.0004887f16;
    printf("h_add %g %g\n", (double)h_add(a, b), (double)h_add((_Float16)65504, (_Float16)32));
    printf("bf_id %g\n", (double)bf_id((__bf16)3.140625f));
    printf("h_neg %g %g\n", (double)h_neg(a), (double)h_neg((_Float16)0));
    printf("h_many %g\n", (double)h_many(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12));
    printf("h_mixed %.9g\n", h_mixed(1.25f, (_Float16)2.5, 3.0, (__bf16)4.0f, 5));
    printf("h_callback %g\n", (double)h_callback(c_many));
    printf("bf_callback %.9g\n", (double)bf_callback(c_bf, 1.75f));
    printf("h_vsum %g\n", h_vsum(3, (double)a, (double)b, (double)(_Float16)0.1));
    printf("xc_many %g\n", (double)c_many(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12));
    return 0;
}
