// array_map — elementwise c[i] = a[i] + b[i] * k. See array_map.xc.
#include <array>
#include <cstdio>
#include <cstdint>
#include "include/bench_time.h"

constexpr uint32_t N = 4096;

int main(int argc, char **argv)
    {
    std::array<uint32_t, N> a, b, c;
    const uint32_t seed = static_cast<uint32_t>(argc);
    for (uint32_t i = 0; i < N; i++) { a[i] = i + seed; b[i] = (i * 3u) + seed; }
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 5000000u; r++)
        for (uint32_t i = 0; i < N; i++) c[i] = a[i] + (b[i] * 7u) + r;
    uint32_t acc = 0;
    for (uint32_t v : c) acc = acc + v;
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", acc, static_cast<long long>(t1 - t0));
    return 0;
    }
