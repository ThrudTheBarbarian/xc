// matrix_mul — multiply two small square matrices, repeatedly. See matrix_mul.xc.
#include <array>
#include <cstdio>
#include <cstdint>
#include "include/bench_time.h"

constexpr uint32_t M = 32;
using Matrix = std::array<uint32_t, M * M>;

int main(int argc, char **argv)
    {
    Matrix a, b, c;
    const uint32_t seed = static_cast<uint32_t>(argc);
    for (uint32_t i = 0; i < M * M; i++) { a[i] = (i + seed) & 15u; b[i] = (i ^ seed) & 15u; }
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 180000u; r++)
        for (uint32_t i = 0; i < M; i++)
            for (uint32_t j = 0; j < M; j++)
                {
                uint32_t s = 0;
                for (uint32_t k = 0; k < M; k++) s = s + (a[i * M + k] * b[k * M + j]);
                c[i * M + j] = s + r;
                }
    uint32_t acc = 0;
    for (uint32_t v : c) acc = acc + v;
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", acc, static_cast<long long>(t1 - t0));
    return 0;
    }
