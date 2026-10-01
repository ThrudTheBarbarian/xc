// float_math — float multiply, accumulated in double. See float_math.xc.
#include <array>
#include <cstdio>
#include <cstdint>
#include "include/bench_time.h"

constexpr uint32_t N = 4096;

int main(int argc, char **argv)
    {
    std::array<float, N> a, b;
    const uint32_t seed = static_cast<uint32_t>(argc);
    for (uint32_t i = 0; i < N; i++)
        {
        a[i] = static_cast<float>((i + seed) % 16u);
        b[i] = static_cast<float>((i % 7u) + 1u);
        }
    double acc = 0.0;
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 400000u; r++)
        for (uint32_t i = 0; i < N; i++) acc = acc + static_cast<double>(a[i] * b[i]);
    int64_t t1 = bench_now_us();
    // Converting acc straight to uint32_t is undefined once the sum exceeds
    // u32; via uint64_t the narrowing is defined and wraps. See float_math.xc.
    std::printf("%u %lld\n", static_cast<uint32_t>(static_cast<uint64_t>(acc)),
                static_cast<long long>(t1 - t0));
    return 0;
    }
