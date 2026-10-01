// poly_dispatch — dispatch through a mixed array of subclasses. See poly_dispatch.xc.
#include <cstdio>
#include <cstdint>
#include <memory>
#include <vector>
#include "include/bench_time.h"

constexpr uint32_t N = 256;

class Op
    {
public:
    explicit Op(uint32_t x) : k(x) {}
    virtual ~Op() = default;
    virtual uint32_t apply(uint32_t v) const { return v + k; }
protected:
    uint32_t k;
    };

class OpMul : public Op
    {
public:
    using Op::Op;
    uint32_t apply(uint32_t v) const override { return v * (k | 1u); }
    };

class OpXor : public Op
    {
public:
    using Op::Op;
    uint32_t apply(uint32_t v) const override { return v ^ k; }
    };

int main(int argc, char **argv)
    {
    const uint32_t seed = static_cast<uint32_t>(argc);
    std::vector<std::unique_ptr<Op>> ops;
    ops.reserve(N);
    for (uint32_t i = 0; i < N; i++)
        {
        if ((i % 3u) == 0)      ops.push_back(std::make_unique<Op>(i + seed));
        else if ((i % 3u) == 1) ops.push_back(std::make_unique<OpMul>(i + seed));
        else                    ops.push_back(std::make_unique<OpXor>(i + seed));
        }
    uint32_t acc = 1;
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 3000000u; r++)
        for (const auto &op : ops) acc = op->apply(acc) + r;
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", acc, static_cast<long long>(t1 - t0));
    return 0;
    }
