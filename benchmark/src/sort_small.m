// sort_small — insertion sort of a small array, repeatedly. See sort_small.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>
#define N 64
int main(int argc, char **argv)
    {
    @autoreleasepool {
        uint32_t a[N]; uint32_t seed = (uint32_t)argc, acc = 0;
        for (uint32_t r = 0; r < 40000; r++)
            {
            for (uint32_t i = 0; i < N; i++)
                a[i] = ((i * 2654435761u) ^ (r * 40503u)) + seed;
            for (uint32_t i = 1; i < N; i++)
                {
                uint32_t v = a[i], j = i;
                while (j > 0 && a[j - 1] > v) { a[j] = a[j - 1]; j = j - 1; }
                a[j] = v;
                }
            acc = acc + a[0] + a[N - 1];
            }
        printf("%u\n", acc);
    }
    return 0;
    }
