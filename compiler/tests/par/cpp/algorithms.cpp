// STL algorithms over custom types, each in a function of its own (a
// function that may throw, such as main with its vectors, stays clang's):
// transform, accumulate, inner_product, count_if, for_each on a class with a
// method, partial_sum, sort with a comparator, minmax_element, fill, iota.
#include <cstdio>
#include <vector>
#include <numeric>
#include <algorithm>

struct V2 { float x, y; };
static V2 operator+(V2 a, V2 b) { return {a.x + b.x, a.y + b.y}; }
static V2 operator*(V2 a, float s) { return {a.x * s, a.y * s}; }

class Particle
    {
public:
    void step(float dt) { p = p + v * dt; }
    long energy() const { return (long)m * (long)(v.x * v.x + v.y * v.y); }
    V2 p, v;
    int m;
    };

static void scale(const std::vector<int>& a, std::vector<int>& b)
    {
    std::transform(a.begin(), a.end(), b.begin(), [](int x) { return x * 3 - (x >> 2); });
    }
static long total(const std::vector<int>& b) { return std::accumulate(b.begin(), b.end(), 0L); }
static long dot(const std::vector<int>& a, const std::vector<int>& b) { return std::inner_product(a.begin(), a.end(), b.begin(), 0L); }
static long negatives(const std::vector<int>& b) { return std::count_if(b.begin(), b.end(), [](int x) { return x < 0; }); }
static void affine(const std::vector<V2>& vs, std::vector<V2>& ws)
    {
    std::transform(vs.begin(), vs.end(), ws.begin(), [](V2 v) { return v * 2.0f + V2{1.0f, -1.0f}; });
    }
static long sumV(const std::vector<V2>& ws)
    {
    long s = 0;
    for (const V2& w : ws)
        s += (long)(w.x + w.y);
    return s;
    }
static void steps(std::vector<Particle>& ps)
    {
    std::for_each(ps.begin(), ps.end(), [](Particle& q) { q.step(0.5f); });
    }
static long energy(const std::vector<Particle>& ps)
    {
    long e = 0;
    for (const Particle& q : ps)
        e += q.energy();
    return e;
    }
static long prefix(const std::vector<int>& b, std::vector<long>& pre)
    {
    std::partial_sum(b.begin(), b.end(), pre.begin());
    return pre.back();
    }
static int range(const std::vector<int>& b)
    {
    auto mm = std::minmax_element(b.begin(), b.end());
    return *mm.first + *mm.second;
    }
static void byResidue(std::vector<int>& c)
    {
    std::sort(c.begin(), c.end(), [](int x, int y) { return (x % 97) < (y % 97) || ((x % 97) == (y % 97) && x < y); });
    }

int main()
    {
    const int n = 20000;
    std::vector<int> a(n), b(n);
    std::iota(a.begin(), a.end(), -7000);
    scale(a, b);
    std::vector<V2> vs(n), ws(n);
    for (int i = 0; i < n; i++)
        vs[i] = {(float)(i % 101), (float)(i % 37) * 0.5f};
    affine(vs, ws);
    std::vector<Particle> ps(n);
    for (int i = 0; i < n; i++)
        ps[i] = Particle{{(float)i, 0}, {(float)(i % 13), (float)(i % 7)}, 1 + i % 5};
    for (int s = 0; s < 4; s++)
        steps(ps);
    std::vector<long> pre(n);
    std::vector<int> c(b.begin(), b.begin() + 5000);
    byResidue(c);
    std::fill(a.begin(), a.begin() + 100, 9);
    std::printf("%ld %ld %ld %ld %ld %ld %d %d %d %d\n", total(b), dot(a, b), negatives(b), sumV(ws), energy(ps),
                prefix(b, pre), c[0], c[4999], range(b), a[50] + a[150]);
    return 0;
    }
