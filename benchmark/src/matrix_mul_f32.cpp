// matrix_mul_f32 — multiply two float matrices, repeatedly. See matrix_mul_f32.xc.
#include <cstdio>
#include <cstdint>
#include <vector>
#include "include/bench_time.h"

constexpr uint32_t M = 128;

int main(int argc, char **argv)
    {
    std::vector<float> a(M * M), b(M * M), c(M * M);
    const uint32_t seed = static_cast<uint32_t>(argc);
    for (uint32_t i = 0; i < M * M; i++)
        { a[i] = static_cast<float>((i + seed) & 15u); b[i] = static_cast<float>((i ^ seed) & 15u); }
    uint32_t acc = 0;
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 10000u; r++)
        {
        a[r % (M * M)] = static_cast<float>(r & 15u);
        for (uint32_t i = 0; i < M; i++)
            for (uint32_t j = 0; j < M; j++)
                {
                float s = 0.0f;
                for (uint32_t k = 0; k < M; k++) s = s + a[i * M + k] * b[k * M + j];
                c[i * M + j] = s;
                }
        acc = acc + static_cast<uint32_t>(c[(r * 7919u) % (M * M)]);
        }
    for (float v : c) acc = acc + static_cast<uint32_t>(v);
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", acc, static_cast<long long>(t1 - t0));
    return 0;
    }
