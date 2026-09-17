// method_call — a virtual method call per iteration. See method_call.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>

@interface Shape : NSObject { @public uint32_t k; }
- (instancetype)initWithK:(uint32_t)x;
- (uint32_t)score;
@end
@implementation Shape
- (instancetype)initWithK:(uint32_t)x { if ((self = [super init])) k = x; return self; }
- (uint32_t)score { return k; }
@end
@interface Boxy : Shape @end
@implementation Boxy
- (uint32_t)score { return k + 1u; }
@end

int main(int argc, char **argv)
    {
    @autoreleasepool {
        uint32_t seed = (uint32_t)argc;
        Shape *s = [[Boxy alloc] initWithK:seed];
        uint32_t acc = 0;
        for (uint32_t r = 0; r < 8000000; r++) acc = acc + [s score] + r;
        printf("%u\n", acc);
    }
    return 0;
    }
