// string_scan — scan bytes for a delimiter and checksum them. See string_scan.xc.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>
#define N 8192
int main(int argc, char **argv)
    {
    @autoreleasepool {
        static uint8_t buf[N]; uint32_t seed = (uint32_t)argc, acc = 0;
        for (uint32_t i = 0; i < N; i++) buf[i] = (uint8_t)(((i * 31u) + seed) & 127u);
        for (uint32_t r = 0; r < 20000; r++)
            {
            uint32_t n = 0;
            for (uint32_t i = 0; i < N; i++)
                { if (buf[i] == 44) n = n + 1; acc = acc + (uint32_t)buf[i]; }
            acc = acc + n;
            }
        printf("%u\n", acc);
    }
    return 0;
    }
