// hash_mix — an integer avalanche chain. See hash_mix.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "include/bench_time.h"
#include <stdint.h>
int main(int argc, char **argv)
    {
    @autoreleasepool {
        uint32_t h = (uint32_t)argc;
        int64_t t0 = bench_now_us();
        for (uint32_t r = 0; r < 640000000; r++)
            {
            h = h ^ (h >> 16);
            h = h * 2246822519u;
            h = h ^ (h >> 13);
            h = h + r;
            }
        int64_t t1 = bench_now_us();
        printf("%u %lld\n", h, (long long)(t1 - t0));
    }
    return 0;
    }
