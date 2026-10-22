/* mandel_deep — the par benchmark (benchmark/par/auto/mandel_deep.xc) in C,
   for the C path: built by clang alone, and by xcc --par-auto. A 4096x4096
   window mostly inside the set, up to 4096 iterations a pixel; prints
   "<checksum> <best_us> <first_us>". */
#include <stdio.h>
#include "bench_time.h"
#define W 4096
#define MAXITER 4096
#define SIZE (W * W)
unsigned counts[SIZE];
int main(void)
{
    unsigned total = 0;
    long long best = 0, first = 0;
    for (unsigned rep = 0; rep < 8; rep++) {
        total = 0;
        long long t0 = bench_now_us();
        for (unsigned i = bench_zero(); i < SIZE; i++) {
            float cx = (float)(i % W) * (1.5f / (float)W) - 1.5f;
            float cy = (float)(i / W) * (1.5f / (float)W) - 0.75f;
            float x = 0.0f, y = 0.0f;
            unsigned k = 0;
            while (k < MAXITER && x * x + y * y < 4.0f) {
                float xt = x * x - y * y + cx;
                y = 2.0f * x * y + cy;
                x = xt;
                k = k + 1;
            }
            counts[i] = k;
            total = total + k;
        }
        bench_keep(total);
        long long t1 = bench_now_us();
        if (rep == 0)
            first = t1 - t0;
        if (rep == 0 || t1 - t0 < best)
            best = t1 - t0;
    }
    printf("%u %lld %lld\n", (total + 500000) / 1000000, best, first);
    return 0;
}
