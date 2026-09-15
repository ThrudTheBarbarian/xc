/* dot.c — C equivalent of dot.xc (products < 65536 so u16-mul == int-mul). */
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
    uint16_t a[48], b[48];
    for (int32_t i = 0; i < 48; i++)
        {
        a[i] = (uint16_t)((i + 1 + seed) & 0xFFFF);
        b[i] = (uint16_t)((i * 2 + 1) & 0xFFFF);
        }
    for (int32_t rep = 0; rep < REPS; rep++)
        for (int32_t i = 0; i < 48; i++)
            acc += (uint16_t)(a[i] * b[i]);
#ifdef BENCH
    printf("%u\n", acc);
#else
    printf("%d\n", acc);
#endif
    return 0;
    }
