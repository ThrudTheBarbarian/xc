// hash_mix — an integer avalanche chain. See hash_mix.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>
int main(int argc, char **argv)
    {
    @autoreleasepool {
        uint32_t h = (uint32_t)argc;
        for (uint32_t r = 0; r < 8000000; r++)
            {
            h = h ^ (h >> 16);
            h = h * 2246822519u;
            h = h ^ (h >> 13);
            h = h + r;
            }
        printf("%u\n", h);
    }
    return 0;
    }
