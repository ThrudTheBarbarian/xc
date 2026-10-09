// saxpy — benchmark/par/saxpy.xc written by hand with OpenMP.
// Same data, same arithmetic, same eight runs, same checksum. CPU only.
#include <stdio.h>
#include <stdint.h>
#include "../../../src/include/bench_time.h"

#define SIZE (16 * 1024 * 1024)

static uint32_t xs[SIZE], ys[SIZE];

int main(void)
{
    for (uint32_t i = 0; i < SIZE; i++)
    {
        xs[i] = i * 2654435761u;
        ys[i] = i;
    }
    uint32_t total = 0;
    int64_t best = 0, first = 0;
    for (uint32_t rep = 0; rep < 8; rep++)
    {
        total = 0;
        int64_t t0 = bench_now_us();
        #pragma omp parallel for reduction(+:total) schedule(static)
        for (uint32_t i = 0; i < SIZE; i++)
        {
            uint32_t v = 3u * xs[i] + ys[i];
            ys[i] = v;
            total += v;
        }
        int64_t t1 = bench_now_us();
        if (rep == 0) first = t1 - t0;
        if (rep == 0 || t1 - t0 < best) best = t1 - t0;
    }
    printf("%u %lld %lld\n", total, (long long)best, (long long)first);
    return 0;
}
