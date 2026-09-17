// mem_copy — copy between arrays element by element. See mem_copy.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "include/bench_time.h"
#include <stdint.h>
#define N 4096
int main(int argc, char **argv)
    {
    @autoreleasepool {
        static uint32_t src[N], dst[N];
        uint32_t seed = (uint32_t)argc;
        for (uint32_t i = 0; i < N; i++) src[i] = i + seed;
        uint32_t acc = 0;
        int64_t t0 = bench_now_us();
        for (uint32_t r = 0; r < 20000; r++)
            {
            for (uint32_t i = 0; i < N; i++) dst[i] = src[i] + r;
            acc = acc + dst[r % N];
            }
        int64_t t1 = bench_now_us();
        printf("%u %lld\n", acc, t1 - t0);
    }
    return 0;
    }
