// string_scan — scan bytes for a delimiter and checksum them. See string_scan.xc.
#include <array>
#include <cstdio>
#include <cstdint>
#include "include/bench_time.h"

constexpr uint32_t N = 8192;

int main(int argc, char **argv)
    {
    std::array<uint8_t, N> buf;
    const uint32_t seed = static_cast<uint32_t>(argc);
    uint32_t acc = 0;
    for (uint32_t i = 0; i < N; i++) buf[i] = static_cast<uint8_t>(((i * 31u) + seed) & 127u);
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 3800000u; r++)
        {
        uint32_t n = 0;
        for (uint8_t c : buf)
            { if (c == 44) n = n + 1; acc = acc + static_cast<uint32_t>(c); }
        acc = acc + n;
        }
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", acc, static_cast<long long>(t1 - t0));
    return 0;
    }
