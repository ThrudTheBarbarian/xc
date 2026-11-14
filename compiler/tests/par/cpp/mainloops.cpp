// Loops in main, which allocates its vectors (an exception may pass
// through it, so it stays clang's): each loop moves into a function of its
// own that xcc takes (Languages.extractLoops) and lifts.
#include <cstdio>
#include <vector>
#include <numeric>
struct V2 { float x, y; };
int main()
    {
    const int n = 1 << 20;
    std::vector<float> a(n), b(n);
    for (int i = 0; i < n; i++)
        a[i] = (float)(i % 1000) * 0.5f;
    for (int i = 0; i < n; i++)
        b[i] = a[i] * 2.0f + 1.0f;
    long s = 0;
    for (int i = 0; i < n; i++)
        s += (long)b[i];
    std::vector<V2> vs(n);
    for (int i = 0; i < n; i++)
        vs[i] = {(float)(i % 7), (float)(i % 11)};
    double t = 0;
    for (const V2& v : vs)
        t += v.x * v.y;
    int firstBig = -1;
    for (int i = 0; i < n; i++)
        if (b[i] > 900.0f) { firstBig = i; break; }
    std::printf("%ld %.1f %d\n", s, t, firstBig);
    return 0;
    }
