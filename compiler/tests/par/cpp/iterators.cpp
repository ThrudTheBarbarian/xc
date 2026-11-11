// A custom iterator and range in range-for loops, std::array, reverse
// iterators, std::span, std::string_view, and algorithms over them.
#include <cstdio>
#include <array>
#include <vector>
#include <span>
#include <string_view>
#include <numeric>
#include <algorithm>

struct Stride
    {
    const int* p; long step;
    struct It { const int* p; long step; int operator*() const { return *p; } It& operator++() { p += step; return *this; } bool operator!=(const It& o) const { return p < o.p; } };
    const int* b; const int* e;
    It begin() const { return It{b, step}; }
    It end() const { return It{e, step}; }
    };

static long spanSum(std::span<const int> s) { long t = 0; for (int x : s) t += x; return t; }
static int vowels(std::string_view sv) { int n = 0; for (char c : sv) n += (c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u'); return n; }

int main()
    {
    std::vector<int> v(2400);
    std::iota(v.begin(), v.end(), -1200);
    long st = 0;
    for (int x : Stride{nullptr, 3, v.data(), v.data() + v.size()}) st += x;
    std::array<double, 100> a{};
    for (size_t i = 0; i < a.size(); i++) a[i] = 1.0 / (double)(i + 1);
    double rs = 0;
    for (auto it = a.rbegin(); it != a.rend(); ++it) rs += *it;
    long sp = spanSum(std::span<const int>(v.data() + 100, 500));
    const char* txt = "the quick brown fox jumps over the lazy dog and keeps running far away";
    int vw = vowels(txt);
    std::vector<int> w(v.rbegin(), v.rbegin() + 50);
    std::reverse(w.begin(), w.end());
    long ws = std::accumulate(w.begin(), w.end(), 0L);
    std::printf("%ld %.6f %ld %d %ld\n", st, rs, sp, vw, ws);
    return 0;
    }
