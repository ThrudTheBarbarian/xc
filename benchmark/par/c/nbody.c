/* nbody — the par benchmark (benchmark/par/auto/nbody.xc) in C, for the C
   path: built by clang alone, and by xcc --par-auto. The x force on each of
   8192 bodies from every other, O(N^2); prints
   "<right/100> <best_us> <first_us>". */
#include <stdio.h>
#include <math.h>
#include "bench_time.h"
#define N (8192 * BENCH_SIDE)
float px[N], py[N], mass[N], fx[N];
int main(void)
{
    unsigned seed = 7;
    for (unsigned i = 0; i < N; i++) {
        seed = seed * 1664525u + 1013904223u;
        px[i] = (float)(seed >> 8) / 16777216.0f;
        seed = seed * 1664525u + 1013904223u;
        py[i] = (float)(seed >> 8) / 16777216.0f;
        mass[i] = 1.0f + (float)(i % 7);
    }
    unsigned right = 0;
    long long best = 0, first = 0;
    for (unsigned rep = 0; rep < 8; rep++) {
        right = 0;
        long long t0 = bench_now_us();
        for (unsigned i = bench_zero(); i < N; i++) {
            float ax = 0.0f;
            for (unsigned j = 0; j < N; j++) {
                float dx = px[j] - px[i];
                float dy = py[j] - py[i];
                float d2 = dx * dx + dy * dy + 0.0001f;
                ax = ax + mass[j] * dx / (d2 * sqrtf(d2));
            }
            fx[i] = ax;
            if (ax > 0.0f)
                right = right + 1;
        }
        bench_keep(right);
        long long t1 = bench_now_us();
        if (rep == 0)
            first = t1 - t0;
        if (rep == 0 || t1 - t0 < best)
            best = t1 - t0;
    }
    printf("%u %lld %lld\n", (right + 50) / 100, best, first);
    return 0;
}
