// branch_mix — data-dependent branches over an array. See branch_mix.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>
#define N 4096
int main(int argc, char **argv)
    {
    @autoreleasepool {
        uint32_t a[N]; uint32_t seed = (uint32_t)argc;
        for (uint32_t i = 0; i < N; i++) a[i] = (i * 2654435761u) + seed;
        uint32_t acc = 0;
        for (uint32_t r = 0; r < 20000; r++)
            for (uint32_t i = 0; i < N; i++)
                { if ((a[i] & 1u) == 0u) acc = acc + a[i]; else acc = acc ^ a[i]; }
        printf("%u\n", acc);
    }
    return 0;
    }
