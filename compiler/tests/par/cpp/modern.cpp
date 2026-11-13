// Modern C++ in loops: std::optional, std::variant with std::visit, tuples
// and structured bindings, CRTP, std::complex, a 2-D std::array, and a
// function pointer table.
#include <cstdio>
#include <optional>
#include <variant>
#include <tuple>
#include <complex>
#include <array>
#include <vector>

static std::optional<int> half(int v) { if (v % 2) return std::nullopt; return v / 2; }

template <typename D> struct Shape { double area() const { return static_cast<const D*>(this)->areaImpl(); } };
struct Sq : Shape<Sq> { double s; double areaImpl() const { return s * s; } };
struct Rc : Shape<Rc> { double w, h; double areaImpl() const { return w * h; } };

template <typename T> static double sumAreas(const std::vector<T>& v) { double s = 0; for (const auto& x : v) s += x.area(); return s; }

static int dbl(int x) { return 2 * x; }
static int sqr(int x) { return x * x; }
static int neg(int x) { return -x; }

int main()
    {
    long os = 0; int none = 0;
    for (int i = 0; i < 1000; i++) { auto h = half(i); if (h) os += *h; else none++; }
    std::vector<std::variant<int, double>> vs;
    for (int i = 0; i < 500; i++) { if (i % 3) vs.emplace_back(i); else vs.emplace_back(i * 0.5); }
    double vsum = 0;
    for (auto& v : vs) vsum += std::visit([](auto x) { return (double)x; }, v);
    std::vector<std::tuple<int, double, char>> ts;
    for (int i = 0; i < 300; i++) ts.emplace_back(i, i * 1.5, (char)('a' + i % 26));
    double tsum = 0;
    for (auto& [k, d, c] : ts) tsum += k + d + c;
    std::vector<Sq> sq(200); std::vector<Rc> rc(150);
    for (size_t i = 0; i < sq.size(); i++) sq[i].s = i * 0.1;
    for (size_t i = 0; i < rc.size(); i++) { rc[i].w = i * 0.2; rc[i].h = 3.0; }
    std::vector<std::complex<double>> zs(512);
    for (size_t i = 0; i < zs.size(); i++) zs[i] = {i * 0.01, -(double)i * 0.02};
    std::complex<double> zp{1.0, 0.0};
    for (auto& z : zs) zp = zp * 0.999 + z;
    std::array<std::array<int, 32>, 32> g{};
    for (int r = 0; r < 32; r++) for (int c = 0; c < 32; c++) g[r][c] = r * c - 3 * r;
    long gs = 0; for (auto& row : g) for (int v : row) gs += v;
    int (*ops[3])(int) = {dbl, sqr, neg};
    long fs = 0; for (int i = 0; i < 900; i++) fs += ops[i % 3](i);
    std::printf("%ld %d %.2f %.2f %.2f %.2f %.4f %.4f %ld %ld\n", os, none, vsum, tsum, sumAreas(sq), sumAreas(rc), zp.real(), zp.imag(), gs, fs);
    return 0;
    }
