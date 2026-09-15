#include <stdio.h>
#include <stdlib.h>
#include <time.h>
void ssve_add(const float*, const float*, float*, unsigned long);
void ssve_nop(void);
__attribute__((noinline)) void neon_add(const float* a, const float* b, float* c, unsigned long n)
    {
    for (unsigned long i = 0; i < n; i++)
        c[i] = a[i] + b[i];
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
    float *a = aligned_alloc(64, maxn * 4), *b = aligned_alloc(64, maxn * 4), *c = aligned_alloc(64, maxn * 4);
    for (unsigned long i = 0; i < maxn; i++)
        {
        a[i] = (float)i;
        b[i] = (float)i;
        }

    /* fixed cost of streaming mode, on its own */
    for (int i = 0; i < 10000; i++)
        ssve_nop();
    double t0 = now_ns();
    for (int i = 0; i < 100000; i++)
        ssve_nop();
    double t1 = now_ns();
    printf("SMSTART+SMSTOP alone: %.1f ns each\n\n", (t1 - t0) / 100000.0);

    printf("%9s %11s %11s %10s\n", "n", "NEON ns", "SSVE ns", "SSVE/NEON");
    unsigned long sz[] = {16, 64, 256, 1024, 4096, 16384, 65536, 262144, 1048576};
    for (int s = 0; s < 9; s++)
        {
        unsigned long n = sz[s];
        int it = n <= 1024 ? 20000 : (n <= 65536 ? 2000 : 100);
        /* warm */
        for (int i = 0; i < 50; i++)
            {
            neon_add(a, b, c, n);
            ssve_add(a, b, c, n);
            }
        t0 = now_ns();
        for (int i = 0; i < it; i++)
            neon_add(a, b, c, n);
        t1 = now_ns();
        double tn = (t1 - t0) / it;
        t0 = now_ns();
        for (int i = 0; i < it; i++)
            ssve_add(a, b, c, n);
        t1 = now_ns();
        double ts = (t1 - t0) / it;
        printf("%9lu %11.1f %11.1f %9.1fx\n", n, tn, ts, ts / tn);
        }
    return 0;
    }
