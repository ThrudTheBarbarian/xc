// float_math — float multiply, accumulated in double. See float_math.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "include/bench_time.h"
#include <stdint.h>
#define N 4096
int main(int argc, char **argv)
    {
    @autoreleasepool {
        static float a[N], b[N];
        uint32_t seed = (uint32_t)argc;
        for (uint32_t i = 0; i < N; i++)
            { a[i] = (float)((i + seed) % 16u); b[i] = (float)((i % 7u) + 1u); }
        double acc = 0.0;
        int64_t t0 = bench_now_us();
        for (uint32_t r = 0; r < 4000; r++)
            for (uint32_t i = 0; i < N; i++) acc = acc + (double)(a[i] * b[i]);
        int64_t t1 = bench_now_us();
        printf("%u %lld\n", (uint32_t)acc, t1 - t0);
    }
    return 0;
    }
