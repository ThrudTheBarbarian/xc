// call_depth — a small non-inlinable call chain in a hot loop. See call_depth.xc.
#include <cstdio>
#include <cstdint>
#include "include/bench_time.h"

namespace
    {
    uint32_t leaf(uint32_t x)  { return (x * 3u) ^ (x >> 2); }
    uint32_t mid(uint32_t x)   { return leaf(x) + leaf(x + 1u); }
    uint32_t outer(uint32_t x) { return mid(x) ^ mid(x + 2u); }
    }

int main(int argc, char **argv)
    {
    const uint32_t seed = static_cast<uint32_t>(argc);
    uint32_t acc = 0;
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 2800000000u; r++) acc = acc + outer(r + seed);
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", acc, static_cast<long long>(t1 - t0));
    return 0;
    }
