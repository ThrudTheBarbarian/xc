// nbody — the par benchmark (benchmark/par/nbody.xc) in C++, plain loops
// over a std::vector of bodies' coordinates: the x force on each of 8192
// bodies from every other, O(N^2); prints "<right/100> <best_us> <first_us>".
#include <cmath>
#include <cstdio>
#include <vector>
#include "../c/bench_time.h"
static const unsigned N = 8192 * BENCH_SIDE;
struct Bodies
    {
    std::vector<float> px, py, mass, fx;
    explicit Bodies(size_t n) : px(n), py(n), mass(n), fx(n) {}
    };
static void forces(Bodies& b)
    {
    const float* px = b.px.data();
    const float* py = b.py.data();
    const float* mass = b.mass.data();
    float* fx = b.fx.data();
    size_t n = b.px.size();
    for (size_t i = bench_zero(); i < n; i++)
        {
        float ax = 0.0f;
        for (size_t j = 0; j < n; j++)
            {
            float dx = px[j] - px[i];
            float dy = py[j] - py[i];
            float d2 = dx * dx + dy * dy + 0.0001f;
            ax = ax + mass[j] * dx / (d2 * std::sqrt(d2));
            }
        fx[i] = ax;
        }
    }
static unsigned right(const Bodies& b)
    {
    unsigned r = 0;
    for (float f : b.fx)
        if (f > 0.0f)
            r = r + 1;
    return r;
    }
int main()
    {
    Bodies b(N);
    unsigned seed = 7;
    for (unsigned i = 0; i < N; i++)
        {
        seed = seed * 1664525u + 1013904223u;
        b.px[i] = (float)(seed >> 8) / 16777216.0f;
        seed = seed * 1664525u + 1013904223u;
        b.py[i] = (float)(seed >> 8) / 16777216.0f;
        b.mass[i] = 1.0f + (float)(i % 7);
        }
    unsigned r = 0;
    long long best = 0, first = 0;
    for (unsigned rep = 0; rep < 8; rep++)
        {
        long long t0 = bench_now_us();
        forces(b);
        r = right(b);
        bench_keep(r);
        long long t1 = bench_now_us();
        if (rep == 0)
            first = t1 - t0;
        if (rep == 0 || t1 - t0 < best)
            best = t1 - t0;
        }
    std::printf("%u %lld %lld\n", (r + 50) / 100, best, first);
    return 0;
    }
