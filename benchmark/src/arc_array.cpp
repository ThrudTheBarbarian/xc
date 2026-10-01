// arc_array — hold objects in an array and walk them. See arc_array.xc.
// The objects are held as std::shared_ptr in a std::vector, so storing them
// pays for reference counting as the ARC version does.
#include <cstdio>
#include <cstdint>
#include <memory>
#include <vector>
#include "include/bench_time.h"

constexpr uint32_t N = 1024;

class Cell
    {
public:
    explicit Cell(uint32_t x) : v_(x) {}
    uint32_t get() const { return v_; }
private:
    uint32_t v_;
    };

int main(int argc, char **argv)
    {
    const uint32_t seed = static_cast<uint32_t>(argc);
    std::vector<std::shared_ptr<Cell>> cells;
    cells.reserve(N);
    for (uint32_t i = 0; i < N; i++) cells.push_back(std::make_shared<Cell>(i + seed));
    uint32_t acc = 0;
    int64_t t0 = bench_now_us();
    for (uint32_t r = 0; r < 3000000u; r++)
        for (const auto &cell : cells) acc = acc + cell->get();
    int64_t t1 = bench_now_us();
    std::printf("%u %lld\n", acc, static_cast<long long>(t1 - t0));
    return 0;
    }
