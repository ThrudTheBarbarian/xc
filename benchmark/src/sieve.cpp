// sieve — sieve of Eratosthenes over a fixed range, repeatedly. See sieve.xc.
#include <array>
#include <cstdio>
#include <cstdint>
#include "include/bench_time.h"

constexpr uint32_t N = 8192;

int main(int argc, char **argv)
    {
    std::array<uint8_t, N> flags;
    const uint32_t seed = static_cast<uint32_t>(argc);
    uint32_t acc = 0;
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 150000u; r++)
        {
        for (uint32_t i = 0; i < N; i++) flags[i] = 1;
        uint32_t count = 0;
        for (uint32_t i = 2; i < N; i++)
            if (flags[i] != 0)
                {
                count = count + 1;
                for (uint32_t j = i + i; j < N; j = j + i) flags[j] = 0;
                }
        acc = acc + count + (r & seed);
        }
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", acc, static_cast<long long>(t1 - t0));
    return 0;
    }
