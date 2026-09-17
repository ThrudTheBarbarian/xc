// sieve — sieve of Eratosthenes over a fixed range, repeatedly. See sieve.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>
#define N 8192
int main(int argc, char **argv)
    {
    @autoreleasepool {
        uint8_t flags[N]; uint32_t seed = (uint32_t)argc, acc = 0;
        for (uint32_t r = 0; r < 2000; r++)
            {
            for (uint32_t i = 0; i < N; i++) flags[i] = 1;
            uint32_t count = 0;
            for (uint32_t i = 2; i < N; i++)
                if (flags[i] != 0)
                    {
                    count = count + 1;
                    for (uint32_t j = i + i; j < N; j = j + i) flags[j] = 0;
                    }
            acc = acc + count + (r & seed);
            }
        printf("%u\n", acc);
    }
    return 0;
    }
