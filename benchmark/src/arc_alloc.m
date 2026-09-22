// arc_alloc — allocate an object per iteration and let ARC free it.
// See arc_alloc.xc. Same object shape, same count, same accumulation.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "include/bench_time.h"
#include <stdint.h>

@interface Node : NSObject
@property (nonatomic) uint32_t v;
- (instancetype)initWithV:(uint32_t)x;
@end

@implementation Node
- (instancetype)initWithV:(uint32_t)x { if ((self = [super init])) _v = x; return self; }
- (uint32_t)get { return _v; }
@end

int main(int argc, char **argv)
    {
    @autoreleasepool {
        uint32_t seed = (uint32_t)argc;
        uint32_t acc  = 0;
        int64_t t0 = bench_now_us();
        for (uint32_t r = 0; r < 80000000; r++)
            {
            Node *n = [[Node alloc] initWithV:r + seed];
            acc = acc + [n get];
            }
        int64_t t1 = bench_now_us();
        printf("%u %lld\n", acc, (long long)(t1 - t0));
    }
    return 0;
    }
