// Results of two integer words, returned from functions xcc reads, called
// plainly and in a try (an invoke): std::pair<long*, bool>, a pair of longs,
// a long and an int, and unordered_map::emplace's pair<iterator, bool>.
// clang gives each as [2 x i64] on arm64, and as { ptr, i8 }, { i64, i64 }
// and { i64, i32 } on x86-64.
#include <cstdio>
#include <stdexcept>
#include <unordered_map>
#include <utility>

static long table[8];

__attribute__((noinline)) std::pair<long*, bool> find(long k)
{
    for (int i = 0; i < 8; i++)
        if (table[i] == k)
            return {&table[i], true};
    return {nullptr, false};
}

__attribute__((noinline)) std::pair<long, long> divmod(long a, long b)
{
    if (b == 0)
        throw std::runtime_error("divide by zero");
    return {a / b, a % b};
}

__attribute__((noinline)) std::pair<long, int> split(long v)
{
    if (v < 0)
        throw std::runtime_error("negative");
    return {v >> 8, (int)(v & 255)};
}

__attribute__((noinline)) std::pair<long*, bool> findOrThrow(long k)
{
    auto r = find(k);
    if (!r.second && k > 60)
        throw std::runtime_error("missing");
    return r;
}

int main(int argc, char**)
{
    for (int i = 0; i < 8; i++)
        table[i] = (i + argc) * 7;
    long sum = 0;
    for (long k = 0; k < 70; k++) {
        auto r = find(k);
        if (r.second)
            sum += (long)(r.first - table) * 100 + k;
    }
    long q = 0;
    for (long i = 0; i < 5; i++) {
        long b = i - 2;
        try {
            auto d = divmod(1000 + b, b);
            q += d.first * 3 + d.second;
        } catch (const std::runtime_error&) {
            q += 1;
        }
    }
    long sp = 0;
    for (long v = -600; v <= 6000; v += 700) {
        try {
            auto p = split(v);
            sp += p.first * 1000 + p.second;
        } catch (const std::runtime_error&) {
            sp -= 1;
        }
    }
    long ft = 0;
    for (long k = 50; k < 70; k++) {
        try {
            auto r = findOrThrow(k);
            ft += r.second ? *r.first : 1;
        } catch (const std::runtime_error&) {
            ft += 100;
        }
    }
    std::unordered_map<int, long> um;
    long ins = 0;
    for (int i = 0; i < 40; i++) {
        auto e = um.emplace(i % 13, (long)i);
        ins += e.second ? e.first->second : 1000;
    }
    std::printf("%ld %ld %ld %ld %ld %zu\n", sum, q, sp, ft, ins, um.size());
    return 0;
}
