// Constructors and destructors in order, copies and moves, unique_ptr and
// shared_ptr, and vectors of objects with non-trivial copies grown in loops.
#include <cstdio>
#include <vector>
#include <memory>
#include <utility>
#include <cstring>

static int live = 0, made = 0, copies = 0, moves = 0;

struct Blob
    {
    int n; int* d;
    explicit Blob(int k) : n(k), d(new int[k]) { for (int i = 0; i < n; i++) d[i] = i * 3; live++; made++; }
    Blob(const Blob& o) : n(o.n), d(new int[o.n]) { std::memcpy(d, o.d, sizeof(int) * n); live++; copies++; }
    Blob(Blob&& o) noexcept : n(o.n), d(o.d) { o.d = nullptr; o.n = 0; live++; moves++; }
    Blob& operator=(Blob o) { std::swap(n, o.n); std::swap(d, o.d); return *this; }
    ~Blob() { delete[] d; live--; }
    long sum() const { long s = 0; for (int i = 0; i < n; i++) s += d[i]; return s; }
    };

struct Guard { int* hits; explicit Guard(int* h) : hits(h) {} ~Guard() { (*hits)++; } };

int main()
    {
    long total = 0;
    int guards = 0;
        {
        std::vector<Blob> v;
        for (int i = 1; i <= 40; i++) v.emplace_back(i * 5);
        std::vector<Blob> w = v;
        for (auto& b : w) total += b.sum();
        Blob x(7);
        Blob y = std::move(x);
        x = y;
        total += x.sum() + y.sum();
        for (int i = 0; i < 25; i++) { Guard g(&guards); total += i; }
        auto up = std::make_unique<Blob>(100);
        std::shared_ptr<Blob> sp = std::make_shared<Blob>(50);
        std::shared_ptr<Blob> sp2 = sp;
        total += up->sum() + sp2->sum() + sp.use_count();
        }
    std::printf("%ld %d %d %d %d\n", total, live, made, guards, copies + moves > 0);
    return 0;
    }
