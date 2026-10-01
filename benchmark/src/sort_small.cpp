// sort_small — insertion sort of a small array, repeatedly. See sort_small.xc.
#include <array>
#include <cstdio>
#include <cstdint>
#include "include/bench_time.h"

constexpr uint32_t N = 64;

int main(int argc, char **argv)
    {
    std::array<uint32_t, N> a;
    const uint32_t seed = static_cast<uint32_t>(argc);
    uint32_t acc = 0;
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 3200000u; r++)
        {
        for (uint32_t i = 0; i < N; i++)
            a[i] = ((i * 2654435761u) ^ (r * 40503u)) + seed;
        for (uint32_t i = 1; i < N; i++)
            {
            uint32_t v = a[i], j = i;
            while (j > 0 && a[j - 1] > v) { a[j] = a[j - 1]; j = j - 1; }
            a[j] = v;
            }
        acc = acc + a.front() + a.back();
        }
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", acc, static_cast<long long>(t1 - t0));
    return 0;
    }
