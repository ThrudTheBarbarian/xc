#include <stdio.h>
#include <stdlib.h>
#include <time.h>
void ssve_poly(const float*, float*, unsigned long);
__attribute__((noinline)) void neon_poly(const float* a, float* c, unsigned long n)
    {
    for (unsigned long i = 0; i < n; i++)
        {
        float x = a[i], v = 1.0f;
        v = v * x + x;
        v = v * x + x;
        v = v * x + x;
        v = v * x + x;
        v = v * x + x;
        v = v * x + x;
        v = v * x + x;
        v = v * x + x;
        c[i] = v;
        }
    }
static double now_ns(void)
    {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e9 + (double)ts.tv_nsec;
    }
int main(void)
    {
    unsigned long maxn = 1048576;
    float *a = aligned_alloc(64, maxn * 4), *c = aligned_alloc(64, maxn * 4);
    for (unsigned long i = 0; i < maxn; i++)
        a[i] = (float)(i % 17) * 0.5f;
    printf("COMPUTE-BOUND (8 FMA/element)\n%9s %11s %11s %10s\n", "n", "NEON ns", "SSVE ns", "SSVE/NEON");
    unsigned long sz[] = {64, 256, 1024, 4096, 16384, 65536, 262144, 1048576};
    for (int s = 0; s < 8; s++)
        {
        unsigned long n = sz[s];
        int it = n <= 1024 ? 20000 : (n <= 65536 ? 2000 : 100);
        for (int i = 0; i < 50; i++)
            {
            neon_poly(a, c, n);
            ssve_poly(a, c, n);
            }
        double t0 = now_ns();
        for (int i = 0; i < it; i++)
            neon_poly(a, c, n);
        double t1 = now_ns();
        double tn = (t1 - t0) / it;
        t0 = now_ns();
        for (int i = 0; i < it; i++)
            ssve_poly(a, c, n);
        t1 = now_ns();
        double ts = (t1 - t0) / it;
        printf("%9lu %11.1f %11.1f %9.2fx\n", n, tn, ts, ts / tn);
        }
    return 0;
    }
