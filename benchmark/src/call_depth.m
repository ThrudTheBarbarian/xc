// call_depth — a small non-inlinable call chain in a hot loop. See call_depth.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>

static uint32_t leaf(uint32_t x)  { return (x * 3u) ^ (x >> 2); }
static uint32_t mid(uint32_t x)   { return leaf(x) + leaf(x + 1u); }
static uint32_t outer_(uint32_t x){ return mid(x) ^ mid(x + 2u); }

int main(int argc, char **argv)
    {
    @autoreleasepool {
        uint32_t seed = (uint32_t)argc;
        uint32_t acc  = 0;
        for (uint32_t r = 0; r < 4000000; r++) acc = acc + outer_(r + seed);
        printf("%u\n", acc);
    }
    return 0;
    }
