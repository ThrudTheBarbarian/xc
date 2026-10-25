#include <stdio.h>
/* C's float-to-integer casts are unchecked: every value in range converts,
   including unsigned ones from 2^31 up, which a 32-bit signed conversion
   would get wrong. */
__attribute__((noinline)) unsigned to_u32(float f) { return (unsigned)f; }
__attribute__((noinline)) unsigned to_u32d(double d) { return (unsigned)d; }
__attribute__((noinline)) int to_i32(float f) { return (int)f; }
__attribute__((noinline)) unsigned short to_u16(float f) { return (unsigned short)f; }
__attribute__((noinline)) long long to_i64(double d) { return (long long)d; }
__attribute__((noinline)) unsigned long long to_u64(double d) { return (unsigned long long)d; }
int main(void)
{
    printf("%u %u %u %d %d %u %lld %llu %llu\n",
           to_u32(3.0e9f), to_u32(7.9f), to_u32d(4294967295.0), to_i32(-2.5f),
           to_i32(2147483520.0f), (unsigned)to_u16(65535.0f), to_i64(-9.0e15),
           to_u64(1.8e19), to_u64(12.0));
    return 0;
}
