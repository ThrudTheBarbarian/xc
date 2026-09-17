// array_sum — sum an array. See array_sum.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>
#define N 4096
int main(int argc, char **argv)
    {
    @autoreleasepool {
        uint32_t a[N]; uint32_t seed = (uint32_t)argc;
        for (uint32_t i = 0; i < N; i++) a[i] = (i * 2654435761u) + seed;
        uint32_t sum = 0;
        for (uint32_t r = 0; r < 20000; r++)
            for (uint32_t i = 0; i < N; i++) sum = sum + a[i];
        printf("%u\n", sum);
    }
    return 0;
    }
