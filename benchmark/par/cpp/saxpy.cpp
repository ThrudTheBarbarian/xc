// saxpy — the par benchmark (benchmark/par/saxpy.xc) in C++, plain loops
// over std::vector: built by clang++ alone, and by xcc, which makes par
// blocks of its loops. y = 3*x + y over 16M integers, a checksum; prints
// "<checksum> <best_us> <first_us>".
#include <cstdio>
#include <vector>
#include "../c/bench_time.h"
#if BENCH_SCALE > 4
#error saxpy stops at BENCH_SCALE 4 (it is bound by memory, not arithmetic)
#endif
static const unsigned SIZE = 16u * 1024 * 1024 * BENCH_SCALE;
static void step(const std::vector<unsigned>& xs, std::vector<unsigned>& ys)
    {
    for (size_t i = bench_zero(); i < ys.size(); i++)
        ys[i] = 3u * xs[i] + ys[i];
    }
static unsigned sum(const std::vector<unsigned>& ys)
    {
    unsigned total = 0;
    for (unsigned v : ys)
        total = total + v;
    return total;
    }
int main()
    {
    std::vector<unsigned> xs(SIZE), ys(SIZE);
    for (unsigned i = 0; i < SIZE; i++)
        {
        xs[i] = i * 2654435761u;
        ys[i] = i;
        }
    unsigned total = 0;
    long long best = 0, first = 0;
    for (unsigned rep = 0; rep < 8; rep++)
        {
        long long t0 = bench_now_us();
        step(xs, ys);
        total = sum(ys);
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
