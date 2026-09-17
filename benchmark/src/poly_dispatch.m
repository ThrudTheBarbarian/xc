// poly_dispatch — dispatch through a mixed array of subclasses. See poly_dispatch.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "include/bench_time.h"
#include <stdint.h>
#define N 256
@interface Op : NSObject { @public uint32_t k; }
- (instancetype)initWithK:(uint32_t)x; - (uint32_t)apply:(uint32_t)v; @end
@implementation Op
- (instancetype)initWithK:(uint32_t)x { if ((self = [super init])) k = x; return self; }
- (uint32_t)apply:(uint32_t)v { return v + k; } @end
@interface OpMul : Op @end
@implementation OpMul - (uint32_t)apply:(uint32_t)v { return v * (k | 1u); } @end
@interface OpXor : Op @end
@implementation OpXor - (uint32_t)apply:(uint32_t)v { return v ^ k; } @end

int main(int argc, char **argv)
    {
    @autoreleasepool {
        Op * __strong ops[N]; uint32_t seed = (uint32_t)argc;
        for (uint32_t i = 0; i < N; i++)
            {
            if ((i % 3u) == 0)      ops[i] = [[Op alloc] initWithK:i + seed];
            else if ((i % 3u) == 1) ops[i] = [[OpMul alloc] initWithK:i + seed];
            else                    ops[i] = [[OpXor alloc] initWithK:i + seed];
            }
        uint32_t acc = 1;
        int64_t t0 = bench_now_us();
        for (uint32_t r = 0; r < 20000; r++)
            for (uint32_t i = 0; i < N; i++) acc = [ops[i] apply:acc] + r;
        int64_t t1 = bench_now_us();
        printf("%u %lld\n", acc, (long long)(t1 - t0));
    }
    return 0;
    }
