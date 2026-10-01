// struct_copy — pass and return a small struct by value. See struct_copy.xc.
#include <cstdio>
#include <cstdint>
#include "include/bench_time.h"

struct Pt { uint32_t x, y; };

namespace
    {
    Pt bump(Pt p, uint32_t d) { return Pt{p.x + d, p.y ^ d}; }
    }

int main(int argc, char **argv)
    {
    const uint32_t seed = static_cast<uint32_t>(argc);
    uint32_t acc = 0;
    Pt p{seed, seed};
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 2200000000u; r++) { p = bump(p, r); acc = acc + p.x + p.y; }
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", acc, static_cast<long long>(t1 - t0));
    return 0;
    }
