// method_call — a virtual method call per iteration. See method_call.xc.
#include <cstdio>
#include <cstdint>
#include <memory>
#include "include/bench_time.h"

class Shape
    {
public:
    explicit Shape(uint32_t x) : k(x) {}
    virtual ~Shape() = default;
    virtual uint32_t score(uint32_t x) const { return k ^ x; }
protected:
    uint32_t k;
    };

class Boxy : public Shape
    {
public:
    using Shape::Shape;
    uint32_t score(uint32_t x) const override { return (k ^ x) + 1u; }
    };

int main(int argc, char **argv)
    {
    const uint32_t seed = static_cast<uint32_t>(argc);
    std::unique_ptr<Shape> s = (argc & 1) ? std::make_unique<Shape>(seed)
                                          : std::make_unique<Boxy>(seed);
    uint32_t acc = 0;
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 1600000000u; r++) acc = acc + s->score(r);
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", acc, static_cast<long long>(t1 - t0));
    return 0;
    }
