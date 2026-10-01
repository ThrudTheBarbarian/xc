// mem_copy — copy between arrays element by element. See mem_copy.xc.
#include <array>
#include <cstdio>
#include <cstdint>
#include "include/bench_time.h"

constexpr uint32_t N = 4096;

int main(int argc, char **argv)
    {
    std::array<uint32_t, N> src, dst;
    const uint32_t seed = static_cast<uint32_t>(argc);
    for (uint32_t i = 0; i < N; i++) src[i] = i + seed;
    uint32_t acc = 0;
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 6800000u; r++)
        {
        for (uint32_t i = 0; i < N; i++) dst[i] = src[i] + r;
        acc = acc + dst[r % N];
        }
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", acc, static_cast<long long>(t1 - t0));
    return 0;
    }
