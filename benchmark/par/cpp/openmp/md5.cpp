// md5 (OpenMP) — the par benchmark (apps/hashcat/md5.xc, hashcat's -a 3 inner loop on
// one block of each candidate) in C++: the candidates as a range, each
// block's words a std::array, the rounds unrolled at compile time (md5.h).
// Built by clang++ alone and by xcc, which makes a par block of the loop.
// Prints "<checksum> <best_us> <first_us>".
#include <cstdio>
#include "../md5.h"
#include "../../c/bench_time.h"
static const unsigned BATCH = 64u * 1024 * 1024 * BENCH_SCALE;
static const uint32_t TAG = 0x6b636168;
static uint32_t hashAll(unsigned from, unsigned to)
    {
    uint32_t total = 0;
    #pragma omp parallel for reduction(+:total)
    for (unsigned i = from; i < to; i++)
        {
        std::array<uint32_t, 16> m{i, TAG, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64, 0};
        md5::State s = md5::init;
        md5::rounds<0, 64>(s, m);
        total += md5::digestSum(s);
        }
    return total;
    }
int main()
    {
    uint32_t total = 0;
    long long best = 0, first = 0;
    for (unsigned rep = 0; rep < 8; rep++)
        {
        long long t0 = bench_now_us();
        total = hashAll(bench_zero(), BATCH);
        bench_keep(total);
        long long t1 = bench_now_us();
        if (rep == 0)
            first = t1 - t0;
        if (rep == 0 || t1 - t0 < best)
            best = t1 - t0;
        }
    std::printf("%u %lld %lld\n", total, best, first);
    return 0;
    }
