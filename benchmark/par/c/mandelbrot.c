/* mandelbrot — the par benchmark (benchmark/par/auto/mandelbrot.xc) in C,
   for the C path: built by clang alone, and by xcc --par-auto. A 2048x2048
   set, 256 iterations at most; prints "<checksum> <best_us> <first_us>". */
#include <stdio.h>
#include "bench_time.h"
#define W 2048
#define SIZE (2048 * 2048)
int main(void)
{
    unsigned total = 0;
    long long best = 0, first = 0;
    for (unsigned rep = 0; rep < 8; rep++) {
        total = 0;
        long long t0 = bench_now_us();
        for (unsigned i = 0; i < SIZE; i++) {
            float cx = (float)(i % W) * (3.0f / 2048.0f) - 2.0f;
            float cy = (float)(i / W) * (3.0f / 2048.0f) - 1.5f;
            float x = 0.0f, y = 0.0f;
            unsigned k = 0;
            while (k < 256 && x * x + y * y < 4.0f) {
                float xt = x * x - y * y + cx;
                y = 2.0f * x * y + cy;
                x = xt;
                k = k + 1;
            }
            total = total + k;
        }
        long long t1 = bench_now_us();
        if (rep == 0)
            first = t1 - t0;
        if (rep == 0 || t1 - t0 < best)
            best = t1 - t0;
    }
    printf("%u %lld %lld\n", (total + 500000) / 1000000, best, first);
    return 0;
}
