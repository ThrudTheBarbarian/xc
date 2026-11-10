// mandelbrot — the par benchmark (benchmark/par/mandelbrot.xc) in C++,
// a plain loop over a std::vector of counts: a 2048x2048 set, 256
// iterations at most; prints "<checksum> <best_us> <first_us>".
#include <cstdio>
#include <vector>
#include "../c/bench_time.h"
static const unsigned W = 2048 * BENCH_SIDE;
static void render(std::vector<unsigned>& counts)
    {
    for (size_t i = bench_zero(); i < counts.size(); i++)
        {
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
        counts[i] = k;
        }
    }
static unsigned sum(const std::vector<unsigned>& counts)
    {
    unsigned total = 0;
    for (unsigned k : counts)
        total = total + k;
    return total;
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
        total = sum(counts);
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
