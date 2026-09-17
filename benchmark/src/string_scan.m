// string_scan — scan bytes for a delimiter and checksum them. See string_scan.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "include/bench_time.h"
#include <stdint.h>
#define N 8192
int main(int argc, char **argv)
    {
    @autoreleasepool {
        static uint8_t buf[N]; uint32_t seed = (uint32_t)argc, acc = 0;
        for (uint32_t i = 0; i < N; i++) buf[i] = (uint8_t)(((i * 31u) + seed) & 127u);
        int64_t t0 = bench_now_us();
        for (uint32_t r = 0; r < 20000; r++)
            {
            uint32_t n = 0;
            for (uint32_t i = 0; i < N; i++)
                { if (buf[i] == 44) n = n + 1; acc = acc + (uint32_t)buf[i]; }
            acc = acc + n;
            }
        int64_t t1 = bench_now_us();
        printf("%u %lld\n", acc, (long long)(t1 - t0));
    }
    return 0;
    }
