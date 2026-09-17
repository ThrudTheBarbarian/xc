// bit_ops — shifts and bitwise logic over an array. See bit_ops.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "include/bench_time.h"
#include <stdint.h>
#define N 4096
int main(int argc, char **argv)
    {
    @autoreleasepool {
        uint32_t a[N]; uint32_t seed = (uint32_t)argc;
        for (uint32_t i = 0; i < N; i++) a[i] = (i * 2654435761u) + seed;
        uint32_t acc = 0;
        int64_t t0 = bench_now_us();
        for (uint32_t r = 0; r < 20000; r++)
            for (uint32_t i = 0; i < N; i++)
                acc = acc + (((a[i] + r) << 3) | ((a[i] + r) >> 5)) ^ 0x0F0F0F0Fu;
        int64_t t1 = bench_now_us();
        printf("%u %lld\n", acc, (long long)(t1 - t0));
    }
    return 0;
    }
