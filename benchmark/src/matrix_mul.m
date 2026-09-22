// matrix_mul — multiply two small square matrices, repeatedly. See matrix_mul.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "include/bench_time.h"
#include <stdint.h>
#define M 32
int main(int argc, char **argv)
    {
    @autoreleasepool {
        static uint32_t a[M * M], b[M * M], c[M * M];
        uint32_t seed = (uint32_t)argc;
        for (uint32_t i = 0; i < M * M; i++)
            { a[i] = (i + seed) & 15u; b[i] = (i ^ seed) & 15u; }
        int64_t t0 = bench_now_us();
        for (uint32_t r = 0; r < 180000; r++)
            for (uint32_t i = 0; i < M; i++)
                for (uint32_t j = 0; j < M; j++)
                    {
                    uint32_t s = 0;
                    for (uint32_t k = 0; k < M; k++) s = s + (a[i * M + k] * b[k * M + j]);
                    c[i * M + j] = s + r;
                    }
        uint32_t acc = 0;
        for (uint32_t i = 0; i < M * M; i++) acc = acc + c[i];
        int64_t t1 = bench_now_us();
        printf("%u %lld\n", acc, (long long)(t1 - t0));
    }
    return 0;
    }
