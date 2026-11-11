// Globals: constructors before main, static locals, static members, a
// namespace, an anonymous namespace, an inline variable and arrays in
// globals updated by loops.
#include <cstdio>
#include <vector>

namespace geo { struct Grid { static int count; int cells[256]; Grid() { count++; for (int i = 0; i < 256; i++) cells[i] = i ^ 0x55; } }; int Grid::count = 0; }
namespace { int hidden[1000]; struct Init { Init() { for (int i = 0; i < 1000; i++) hidden[i] = i * 3 % 17; } } init; }
inline int shared[64] = {1, 2, 3};
geo::Grid g1, g2;
std::vector<int> table = [] { std::vector<int> t(300); for (int i = 0; i < 300; i++) t[i] = i * i % 101; return t; }();

static int counter() { static int n = 0; return ++n; }
static int lazy() { static std::vector<int> v = [] { std::vector<int> r(50); for (int i = 0; i < 50; i++) r[i] = i; return r; }(); int s = 0; for (int x : v) s += x; return s; }

int main()
    {
    for (int i = 0; i < 64; i++) shared[i] += i;
    long h = 0; for (int i = 0; i < 1000; i++) h += hidden[i];
    long gs = 0; for (int i = 0; i < 256; i++) gs += g1.cells[i] + 2 * g2.cells[i];
    long ts = 0; for (int x : table) ts += x;
    long ss = 0; for (int i = 0; i < 64; i++) ss += shared[i];
    int c = 0; for (int i = 0; i < 10; i++) c = counter();
    std::printf("%ld %ld %ld %ld %d %d %d\n", h, gs, ts, ss, c, lazy() + lazy(), geo::Grid::count);
    return 0;
    }
