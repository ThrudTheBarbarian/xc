// arc_alloc — allocate an object per iteration and let ARC free it.
// See arc_alloc.xc. Same object shape, same count, same accumulation.
#import <Foundation/Foundation.h>
#include <stdio.h>
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
        for (uint32_t r = 0; r < 2000000; r++)
            {
            Node *n = [[Node alloc] initWithV:r + seed];
            acc = acc + [n get];
            }
        printf("%u\n", acc);
    }
    return 0;
    }
