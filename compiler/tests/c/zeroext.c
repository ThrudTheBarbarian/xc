#include <stdio.h>
/* unsigned short / char parameters across the boundary between functions
   xcc compiles and functions clang compiles (any using a builtin the C
   reader does not read). */
__attribute__((noinline)) unsigned xc_side(unsigned short v, unsigned char c)
{   /* read by xcc */
    return (v > 40000 ? 1000000u : 0u) + v + (c > 200 ? 7u : 0u) + c;
}
__attribute__((noinline)) unsigned clang_side(unsigned short v, unsigned char c)
{   /* compiled by clang: the popcount */
    return (unsigned)__builtin_popcount(v) * 100000u + (v > 40000 ? 1000000u : 0u) + v + c;
}
__attribute__((noinline)) unsigned clang_calls_xc(unsigned x)
{
    unsigned short v = (unsigned short)x; unsigned char c = (unsigned char)(x >> 3);
    return xc_side(v, c) + (unsigned)__builtin_popcount(x);
}
__attribute__((noinline)) unsigned xc_calls_clang(unsigned x)
{
    unsigned short v = (unsigned short)x; unsigned char c = (unsigned char)(x >> 3);
    return clang_side(v, c);
}
int main(void)
{
    printf("%u %u %u %u\n", clang_calls_xc(65535u), clang_calls_xc(0x1FFF8u),
           xc_calls_clang(65535u), xc_calls_clang(0x1FFF8u));
    return 0;
}
