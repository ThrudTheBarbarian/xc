// matrix_mul_f32 — multiply two float matrices, repeatedly. See matrix_mul_f32.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include "include/bench_time.h"
#include <stdint.h>
#define M 128
int main(int argc, char **argv)
    {
    @autoreleasepool {
        float *a = malloc(sizeof(float) * M * M), *b = malloc(sizeof(float) * M * M), *c = malloc(sizeof(float) * M * M);
        uint32_t seed = (uint32_t)argc;
        for (uint32_t i = 0; i < M * M; i++)
            { a[i] = (float)((i + seed) & 15u); b[i] = (float)((i ^ seed) & 15u); }
        uint32_t acc = 0;
        int64_t t0 = bench_now_us();
        for (uint32_t r = 0; r < 10000; r++)
            {
            a[r % (M * M)] = (float)(r & 15u);
            for (uint32_t i = 0; i < M; i++)
                for (uint32_t j = 0; j < M; j++)
                    {
                    float s = 0.0f;
                    for (uint32_t k = 0; k < M; k++) s = s + a[i * M + k] * b[k * M + j];
                    c[i * M + j] = s;
                    }
            acc = acc + (uint32_t)c[(r * 7919u) % (M * M)];
            }
        for (uint32_t i = 0; i < M * M; i++) acc = acc + (uint32_t)c[i];
        int64_t t1 = bench_now_us();
        printf("%u %lld\n", acc, (long long)(t1 - t0));
        free(a); free(b); free(c);
    }
    return 0;
    }
