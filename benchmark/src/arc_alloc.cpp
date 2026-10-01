// arc_alloc — allocate an object per iteration and let ARC free it.
// See arc_alloc.xc. Same object shape, same count, same accumulation.
// Each object is a std::shared_ptr from std::make_shared, so the C++ version
// also pays for a heap allocation and reference counting per iteration.
#include <cstdio>
#include <cstdint>
#include <memory>
#include "include/bench_time.h"

class Node
    {
public:
    explicit Node(uint32_t x) : v_(x) {}
    uint32_t get() const { return v_; }
private:
    uint32_t v_;
    };

int main(int argc, char **argv)
    {
    const uint32_t seed = static_cast<uint32_t>(argc);
    uint32_t acc = 0;
    std::shared_ptr<Node> keep = std::make_shared<Node>(seed);
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 80000000u; r++)
        {
        std::shared_ptr<Node> n = std::make_shared<Node>(r + seed);
        acc = (acc ^ n->get()) + keep->get();
        keep = n;
        }
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", acc, static_cast<long long>(t1 - t0));
    return 0;
    }
