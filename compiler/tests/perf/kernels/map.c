/* map.c — C equivalent of map.xc. */
#include <stdio.h>
#include <stdint.h>
#ifndef REPS
#define REPS 400
#endif
int main(int argc, char** argv)
    {
    (void)argv;
#ifdef BENCH
    int32_t seed = argc;
    uint32_t acc = 0;
#else
    int32_t seed = 0;
    int32_t acc = 0;
#endif
    uint16_t a[64], b[64];
    for (int32_t i = 0; i < 64; i++)
        a[i] = (uint16_t)((i * 3 + seed) & 0xFFFF);
    for (int32_t rep = 0; rep < REPS; rep++)
        {
        for (int32_t i = 0; i < 64; i++)
            b[i] = (uint16_t)((a[i] * 5 + 7) & 0xFFFF);
        for (int32_t i = 0; i < 64; i++)
            acc += b[i];
        }
#ifdef BENCH
    printf("%u\n", acc);
#else
    printf("%d\n", acc);
#endif
    return 0;
    }
