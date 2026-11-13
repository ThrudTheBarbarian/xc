// Loops over what clang writes as LLVM intrinsics: bit counts, rotates and
// byte swaps, integer abs/min/max, and the float functions (floor, ceil,
// trunc, round, sqrt, fabs, fmin, fmax, copysign, fma).
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <bit>
#include <algorithm>
#include <cstdlib>

static unsigned bits(const uint32_t* a, int n)
    {
    unsigned s = 0;
    for (int i = 0; i < n; i++)
        s += (unsigned)std::popcount(a[i]) + (unsigned)std::countl_zero(a[i] | 1u) + (unsigned)std::countr_zero(a[i] | 0x80000000u);
    return s;
    }

static uint64_t swaps(const uint32_t* a, int n)
    {
    uint64_t s = 0;
    for (int i = 0; i < n; i++)
        s += __builtin_bswap32(a[i]) ^ std::rotl(a[i], 5) ^ std::rotr(a[i], 11);
    return s;
    }

static long ints(const int* a, int n)
    {
    long s = 0;
    for (int i = 0; i < n; i++)
        s += std::abs(a[i]) + std::min(a[i], 7) + std::max(a[i], -3) + std::clamp(a[i], -50, 50);
    return s;
    }

static double floats(const double* x, int n)
    {
    double s = 0;
    for (int i = 0; i < n; i++)
        {
        double v = x[i];
        s += std::floor(v) + std::ceil(v) + std::trunc(v) + std::round(v) + std::sqrt(std::fabs(v))
           + std::fmin(v, 1.5) + std::fmax(v, -1.5) + std::copysign(2.0, v) + std::fma(v, 0.5, 1.0);
        }
    return s;
    }

static float floatsF(const float* x, int n)
    {
    float s = 0;
    for (int i = 0; i < n; i++)
        s += std::floor(x[i]) + std::sqrt(std::fabs(x[i])) + std::fmin(x[i], 0.25f) + std::fma(x[i], 2.0f, -1.0f);
    return s;
    }

int main()
    {
    const int n = 4096;
    static uint32_t u[n];
    static int a[n];
    static double x[n];
    static float f[n];
    for (int i = 0; i < n; i++)
        {
        u[i] = (uint32_t)i * 2654435761u;
        a[i] = (i * 37) % 201 - 100;
        x[i] = (i % 97) * 0.37 - 17.9;
        f[i] = (float)((i % 53) * 0.21 - 5.3);
        }
    std::printf("%u %llu %ld %.6f %.4f\n", bits(u, n), (unsigned long long)swaps(u, n), ints(a, n), floats(x, n), (double)floatsF(f, n));
    return 0;
    }
