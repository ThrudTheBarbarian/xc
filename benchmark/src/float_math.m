// float_math — float multiply, accumulated in double. See float_math.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>
#define N 4096
int main(int argc, char **argv)
    {
    @autoreleasepool {
        static float a[N], b[N];
        uint32_t seed = (uint32_t)argc;
        for (uint32_t i = 0; i < N; i++)
            { a[i] = (float)((i + seed) % 16u); b[i] = (float)((i % 7u) + 1u); }
        double acc = 0.0;
        for (uint32_t r = 0; r < 4000; r++)
            for (uint32_t i = 0; i < N; i++) acc = acc + (double)(a[i] * b[i]);
        printf("%u\n", (uint32_t)acc);
    }
    return 0;
    }
