// mem_copy — copy between arrays element by element. See mem_copy.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>
#define N 4096
int main(int argc, char **argv)
    {
    @autoreleasepool {
        static uint32_t src[N], dst[N];
        uint32_t seed = (uint32_t)argc;
        for (uint32_t i = 0; i < N; i++) src[i] = i + seed;
        uint32_t acc = 0;
        for (uint32_t r = 0; r < 20000; r++)
            {
            for (uint32_t i = 0; i < N; i++) dst[i] = src[i] + r;
            acc = acc + dst[r % N];
            }
        printf("%u\n", acc);
    }
    return 0;
    }
