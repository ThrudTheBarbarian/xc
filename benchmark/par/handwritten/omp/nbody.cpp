// nbody — benchmark/par/nbody.xc written by hand with OpenMP.
// Same data, same arithmetic, same eight runs, same checksum. The par block
// becomes one #pragma; the reduction becomes a reduction clause. CPU only.
#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include "../../../src/include/bench_time.h"

#define N 8192

static float px[N], py[N], mass[N], fx[N];

int main(void)
{
    uint32_t seed = 7;
    for (uint32_t i = 0; i < N; i++)
    {
        seed = seed * 1664525u + 1013904223u;
        px[i] = (float)(seed >> 8) / 16777216.0f;
        seed = seed * 1664525u + 1013904223u;
        py[i] = (float)(seed >> 8) / 16777216.0f;
        mass[i] = 1.0f + (float)(i % 7);
    }
    uint32_t right = 0;
    int64_t best = 0, first = 0;
    for (uint32_t rep = 0; rep < 8; rep++)
    {
        right = 0;
        int64_t t0 = bench_now_us();
        #pragma omp parallel for reduction(+:right) schedule(static)
        for (uint32_t i = 0; i < N; i++)
        {
            float ax = 0.0f;
            for (uint32_t j = 0; j < N; j++)
            {
                float dx = px[j] - px[i];
                float dy = py[j] - py[i];
                float d2 = dx * dx + dy * dy + 0.0001f;
                ax = ax + mass[j] * dx / (d2 * sqrtf(d2));
            }
            fx[i] = ax;
            if (ax > 0.0f)
                right++;
        }
        int64_t t1 = bench_now_us();
        if (rep == 0) first = t1 - t0;
        if (rep == 0 || t1 - t0 < best) best = t1 - t0;
    }
    printf("%u %lld %lld\n", (right + 50u) / 100u,
           (long long)best, (long long)first);
    return 0;
}
