// mandelbrot — benchmark/par/mandelbrot.xc written by hand with OpenMP.
// Same data, same arithmetic, same eight runs, same checksum. The par block
// becomes one #pragma; the reduction becomes a reduction clause. CPU only:
// there is no GPU version of this, on any GPU, from this source.
#include <stdio.h>
#include <stdint.h>
#include "../../../src/include/bench_time.h"

#define W 2048
#define SIZE (2048 * 2048)

int main(void)
{
    uint32_t total = 0;
    int64_t best = 0, first = 0;
    for (uint32_t rep = 0; rep < 8; rep++)
    {
        total = 0;
        int64_t t0 = bench_now_us();
        #pragma omp parallel for reduction(+:total) schedule(static)
        for (uint32_t i = 0; i < SIZE; i++)
        {
            float cx = (float)(i % W) * (3.0f / 2048.0f) - 2.0f;
            float cy = (float)(i / W) * (3.0f / 2048.0f) - 1.5f;
            float x = 0.0f, y = 0.0f;
            uint32_t k = 0;
            while (k < 256 && x * x + y * y < 4.0f)
            {
                float xt = x * x - y * y + cx;
                y = 2.0f * x * y + cy;
                x = xt;
                k++;
            }
            total += k;
        }
        int64_t t1 = bench_now_us();
        if (rep == 0) first = t1 - t0;
        if (rep == 0 || t1 - t0 < best) best = t1 - t0;
    }
    printf("%u %lld %lld\n", (total + 500000u) / 1000000u,
           (long long)best, (long long)first);
    return 0;
}
