// hash_mix — an integer avalanche chain. See hash_mix.xc.
#include <cstdio>
#include <cstdint>
#include "include/bench_time.h"

int main(int argc, char **argv)
    {
    uint32_t h = static_cast<uint32_t>(argc);
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 640000000u; r++)
        {
        h = h ^ (h >> 16);
        h = h * 2246822519u;
        h = h ^ (h >> 13);
        h = h + r;
        }
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", h, static_cast<long long>(t1 - t0));
    return 0;
    }
