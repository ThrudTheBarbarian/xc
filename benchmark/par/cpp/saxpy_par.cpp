// saxpy with the C++17 parallel algorithms: std::transform and std::reduce
// with std::execution::par (build with -std=c++17; on macOS clang++ also
// needs -fexperimental-library). Same work and output as saxpy.cpp.
#include <algorithm>
#include <cstdio>
#include <execution>
#include <numeric>
#include <vector>
#include "../c/bench_time.h"
#if BENCH_SCALE > 4
#error saxpy stops at BENCH_SCALE 4 (it is bound by memory, not arithmetic)
#endif
static const unsigned SIZE = 16u * 1024 * 1024 * BENCH_SCALE;
static void step(const std::vector<unsigned>& xs, std::vector<unsigned>& ys)
    {
    std::transform(std::execution::par, xs.begin() + bench_zero(), xs.end(), ys.begin(), ys.begin(),
                   [](unsigned x, unsigned y) { return 3u * x + y; });
    }
static unsigned sum(const std::vector<unsigned>& ys)
    {
    return std::reduce(std::execution::par, ys.begin(), ys.end(), 0u);
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
