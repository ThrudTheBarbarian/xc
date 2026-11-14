// md5_mask (OpenMP) — the par benchmark (apps/hashcat/md5_mask.xc, hashcat's mask
// attack: a fixed prefix hashed once per outer item, the last word varied in
// the inner loop) in C++, the rounds unrolled at compile time (md5.h): steps
// 0-11 once per outer item, 12-63 per inner one. Prints "<checksum> <best_us>
// <first_us>".
#include <cstdio>
#include "../md5.h"
#include "../../c/bench_time.h"
static const unsigned OUTER = 1024u * 1024 * BENCH_SCALE;
static const unsigned INNER = 64;
static uint32_t hashAll(unsigned from, unsigned to)
    {
    uint32_t total = 0;
    #pragma omp parallel for reduction(+:total)
    for (unsigned p = from; p < to; p++)
        {
        std::array<uint32_t, 16> m{p, 0x6b636168, 0x74736168, 0x6d786378, 0x31323334, 0x35363738, 0x61626364,
                                   0x65666768, 0x696a6b6c, 0x6d6e6f70, 0x71727374, 0x75767778, 0, 0x80, 416, 0};
        md5::State prefix = md5::init;
        md5::rounds<0, 12>(prefix, m);
        for (unsigned j = 0; j < INNER; j++)
            {
            m[12] = p * INNER + j;
            md5::State s = prefix;
            md5::rounds<12, 64>(s, m);
            total += md5::digestSum(s);
            }
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
        total = hashAll(bench_zero(), OUTER);
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
