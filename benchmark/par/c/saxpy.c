/* saxpy — the par benchmark (benchmark/par/auto/saxpy.xc) in C, for the C
   path: built by clang alone, and by xcc --par-auto, which makes par blocks
   of its loops. y = 3*x + y over 16M integers, a checksum; prints
   "<checksum> <best_us> <first_us>". */
#include <stdio.h>
#include "bench_time.h"
#define SIZE (16 * 1024 * 1024)
unsigned xs[SIZE];
unsigned ys[SIZE];
int main(void)
{
    for (unsigned i = 0; i < SIZE; i++) {
        xs[i] = i * 2654435761u;
        ys[i] = i;
    }
    unsigned total = 0;
    long long best = 0, first = 0;
    for (unsigned rep = 0; rep < 8; rep++) {
        total = 0;
        long long t0 = bench_now_us();
        for (unsigned i = bench_zero(); i < SIZE; i++) {
            unsigned v = 3u * xs[i] + ys[i];
            ys[i] = v;
            total = total + v;
        }
        bench_keep(total);
        long long t1 = bench_now_us();
        if (rep == 0)
            first = t1 - t0;
        if (rep == 0 || t1 - t0 < best)
            best = t1 - t0;
    }
    printf("%u %lld %lld\n", total, best, first);
    return 0;
}
