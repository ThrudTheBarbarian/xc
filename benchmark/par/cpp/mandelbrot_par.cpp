// mandelbrot with std::for_each and std::execution::par over the pixels'
// counts (each pixel's index from its address). Same work and output as
// mandelbrot.cpp.
#include <algorithm>
#include <cstdio>
#include <execution>
#include <numeric>
#include <vector>
#include "../c/bench_time.h"
static const unsigned W = 2048 * BENCH_SIDE;
static void render(std::vector<unsigned>& counts)
    {
    unsigned* base = counts.data() + bench_zero();
    std::for_each(std::execution::par, counts.begin(), counts.end(), [base](unsigned& out)
        {
        size_t i = (size_t)(&out - base);
        float cx = (float)(i % W) * (3.0f / (float)W) - 2.0f;
        float cy = (float)(i / W) * (3.0f / (float)W) - 1.5f;
        float x = 0.0f, y = 0.0f;
        unsigned k = 0;
        while (k < 256 && x * x + y * y < 4.0f)
            {
            float xt = x * x - y * y + cx;
            y = 2.0f * x * y + cy;
            x = xt;
            k = k + 1;
            }
        out = k;
        });
    }
int main()
    {
    std::vector<unsigned> counts((size_t)W * W);
    unsigned total = 0;
    long long best = 0, first = 0;
    for (unsigned rep = 0; rep < 8; rep++)
        {
        long long t0 = bench_now_us();
        render(counts);
        total = std::reduce(std::execution::par, counts.begin(), counts.end(), 0u);
        bench_keep(total);
        long long t1 = bench_now_us();
        if (rep == 0)
            first = t1 - t0;
        if (rep == 0 || t1 - t0 < best)
            best = t1 - t0;
        }
    std::printf("%u %lld %lld\n", (total + 500000) / 1000000, best, first);
    return 0;
    }
