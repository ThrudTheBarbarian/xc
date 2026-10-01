// branch_mix — data-dependent branches over an array. See branch_mix.xc.
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
    uint32_t acc = 0;
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 500000u; r++)
        for (uint32_t v : a)
            { if ((v & 1u) == 0u) acc = acc + v; else acc = acc ^ v; }
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", acc, static_cast<long long>(t1 - t0));
    return 0;
    }
