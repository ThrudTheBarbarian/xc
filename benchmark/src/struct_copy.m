// struct_copy — pass and return a small struct by value. See struct_copy.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>
typedef struct { uint32_t x, y; } Pt;
static Pt bump(Pt p, uint32_t d) { Pt q; q.x = p.x + d; q.y = p.y ^ d; return q; }
int main(int argc, char **argv)
    {
    @autoreleasepool {
        uint32_t seed = (uint32_t)argc, acc = 0;
        Pt p; p.x = seed; p.y = seed;
        for (uint32_t r = 0; r < 4000000; r++) { p = bump(p, r); acc = acc + p.x + p.y; }
        printf("%u\n", acc);
    }
    return 0;
    }
