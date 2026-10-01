// array_sum — sum an array. See array_sum.xc.
#include <array>
#include <cstdio>
#include <cstdint>
#include "include/bench_time.h"

constexpr uint32_t N = 4096;

int main(int argc, char **argv)
    {
    std::array<uint32_t, N> a;
    const uint32_t seed = static_cast<uint32_t>(argc);
    for (uint32_t i = 0; i < N; i++) a[i] = (i * 2654435761u) + seed;
    uint32_t sum = 0;
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 7000000u; r++)
        for (uint32_t v : a) sum = sum + v;
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", sum, static_cast<long long>(t1 - t0));
    return 0;
    }
