// array_map — elementwise c[i] = a[i] + b[i] * k. See array_map.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "include/bench_time.h"
#include <stdint.h>
#define N 4096
int main(int argc, char **argv)
    {
    @autoreleasepool {
        static uint32_t a[N], b[N], c[N];
        uint32_t seed = (uint32_t)argc;
        for (uint32_t i = 0; i < N; i++) { a[i] = i + seed; b[i] = (i * 3u) + seed; }
        int64_t t0 = bench_now_us();
        for (uint32_t r = 0; r < 20000; r++)
            for (uint32_t i = 0; i < N; i++) c[i] = a[i] + (b[i] * 7u) + r;
        uint32_t acc = 0;
        for (uint32_t i = 0; i < N; i++) acc = acc + c[i];
        int64_t t1 = bench_now_us();
        printf("%u %lld\n", acc, t1 - t0);
    }
    return 0;
    }
