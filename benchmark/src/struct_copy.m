// struct_copy — pass and return a small struct by value. See struct_copy.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "include/bench_time.h"
#include <stdint.h>
typedef struct { uint32_t x, y; } Pt;
static Pt bump(Pt p, uint32_t d) { Pt q; q.x = p.x + d; q.y = p.y ^ d; return q; }
int main(int argc, char **argv)
    {
    @autoreleasepool {
        uint32_t seed = (uint32_t)argc, acc = 0;
        Pt p; p.x = seed; p.y = seed;
        int64_t t0 = bench_now_us();
        for (uint32_t r = 0; r < 4000000; r++) { p = bump(p, r); acc = acc + p.x + p.y; }
        int64_t t1 = bench_now_us();
        printf("%u %lld\n", acc, (long long)(t1 - t0));
    }
    return 0;
    }
