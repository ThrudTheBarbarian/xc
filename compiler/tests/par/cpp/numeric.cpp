// Numeric kernels on std::vector: a matrix product, a stencil, a prefix sum
// (carried), a histogram (scattered stores), and integer arithmetic at the
// edges: unsigned wrap, division and modulo of negatives, 64-bit products,
// shifts, mixed float/int conversions.
#include <cstdio>
#include <cstdint>
#include <vector>

static void matmul(const std::vector<double>& a, const std::vector<double>& b, std::vector<double>& c, int n)
    {
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            {
            double s = 0;
            for (int k = 0; k < n; k++) s += a[i * n + k] * b[k * n + j];
            c[i * n + j] = s;
            }
    }

static void stencil(const float* in, float* out, int n) { for (int i = 1; i < n - 1; i++) out[i] = 0.25f * in[i - 1] + 0.5f * in[i] + 0.25f * in[i + 1]; }

static void prefix(const int* in, long* out, int n) { long s = 0; for (int i = 0; i < n; i++) { s += in[i]; out[i] = s; } }

static void hist(const uint8_t* d, int n, unsigned* h) { for (int i = 0; i < n; i++) h[d[i] >> 4]++; }

static int64_t mixed(const int32_t* a, int n)
    {
    int64_t s = 0;
    for (int i = 0; i < n; i++)
        {
        int32_t x = a[i];
        uint32_t u = (uint32_t)x * 2654435761u;
        s += (int64_t)x * x + (x / 7) + (x % 7) + (u >> 13) + ((int64_t)x << 3) + (int)((float)x * 0.5f);
        }
    return s;
    }

int main()
    {
    const int n = 48;
    std::vector<double> a(n * n), b(n * n), c(n * n);
    for (int i = 0; i < n * n; i++) { a[i] = (i % 11) * 0.5; b[i] = (i % 7) - 3.0; }
    matmul(a, b, c, n);
    double cs = 0; for (double x : c) cs += x;
    std::vector<float> in(4096), out(4096, 0.0f);
    for (int i = 0; i < 4096; i++) in[i] = (float)((i * 13) % 101);
    stencil(in.data(), out.data(), 4096);
    float ss = 0; for (float x : out) ss += x;
    std::vector<int> pi(2000); std::vector<long> po(2000);
    for (int i = 0; i < 2000; i++) pi[i] = (i % 9) - 4;
    prefix(pi.data(), po.data(), 2000);
    std::vector<uint8_t> d(10000); unsigned h[16] = {0};
    for (int i = 0; i < 10000; i++) d[i] = (uint8_t)(i * 31);
    hist(d.data(), 10000, h);
    std::vector<int32_t> mi(3000);
    for (int i = 0; i < 3000; i++) mi[i] = (i * 7919) % 20001 - 10000;
    std::printf("%.1f %.2f %ld %u %u %lld\n", cs, ss, po[1999] + po[777], h[3], h[15], (long long)mixed(mi.data(), 3000));
    return 0;
    }
