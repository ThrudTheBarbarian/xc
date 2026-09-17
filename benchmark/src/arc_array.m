// arc_array — hold objects in an array and walk them. See arc_array.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>
#define N 1024

@interface Cell : NSObject
- (instancetype)initWithV:(uint32_t)x;
- (uint32_t)get;
@end
@implementation Cell { uint32_t _vv; }
- (instancetype)initWithV:(uint32_t)x { if ((self = [super init])) _vv = x; return self; }
- (uint32_t)get { return _vv; }
@end

int main(int argc, char **argv)
    {
    @autoreleasepool {
        uint32_t seed = (uint32_t)argc;
        Cell * __strong cells[N];
        for (uint32_t i = 0; i < N; i++) cells[i] = [[Cell alloc] initWithV:i + seed];
        uint32_t acc = 0;
        for (uint32_t r = 0; r < 20000; r++)
            for (uint32_t i = 0; i < N; i++) acc = acc + [cells[i] get];
        printf("%u\n", acc);
    }
    return 0;
    }
