/* reduce.c — C equivalent of reduce.xc for the wall-clock-vs-reference bench.
   Bit-identical computation (values stay in u16 range so xtc's no-same-width
   promotion and C's int promotion agree). See reduce.xc for the -DBENCH scheme. */
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
    uint32_t sum = 0;
#else
    int32_t seed = 0;
    int32_t sum = 0;
#endif
    uint16_t a[64];
    for (int32_t i = 0; i < 64; i++)
        a[i] = (uint16_t)((i * 7 + 3 + seed) & 0xFFFF);
    for (int32_t rep = 0; rep < REPS; rep++)
        for (int32_t i = 0; i < 64; i++)
            sum += a[i];
#ifdef BENCH
    printf("%u\n", sum);
#else
    printf("%d\n", sum);
#endif
    return 0;
    }
