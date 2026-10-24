/* perlin — the par benchmark (benchmark/par/auto/perlin.xc) in C, for the C
   path: built by clang alone, and by xcc --par-auto. Four octaves of 2D
   Perlin noise over a 2048x2048 image; prints "<tenths> <best_us> <first_us>". */
#include <stdio.h>
#include "bench_time.h"
#define W (2048 * BENCH_SIDE)
#define SIZE (W * W)
unsigned perm[512];
unsigned char img[SIZE];
static float fade(float t) { return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f); }
static float lerp(float t, float a, float b) { return a + t * (b - a); }
static float grad(unsigned h, float x, float y)
{
    unsigned g = h & 7;
    float u = g < 4 ? x : y;
    float v = g < 4 ? y : x;
    float a = (g & 1) != 0 ? 0.0f - u : u;
    float b = (g & 2) != 0 ? 0.0f - 2.0f * v : 2.0f * v;
    return a + b;
}
int main(void)
{
    unsigned seed = 12345;
    for (unsigned i = 0; i < 256; i++)
        perm[i] = i;
    for (unsigned i = 0; i < 256; i++) {
        seed = seed * 1103515245u + 12345u;
        unsigned j = i + (seed >> 16) % (256 - i);
        unsigned t = perm[i];
        perm[i] = perm[j];
        perm[j] = t;
    }
    for (unsigned i = 0; i < 256; i++)
        perm[i + 256] = perm[i];
    unsigned total = 0;
    long long best = 0, first = 0;
    for (unsigned rep = 0; rep < 8; rep++) {
        total = 0;
        long long t0 = bench_now_us();
        #pragma omp parallel for reduction(+:total)
        for (unsigned i = bench_zero(); i < SIZE; i++) {
            float x = (float)(i % W) / 256.0f;
            float y = (float)(i / W) / 256.0f;
            float sum = 0.0f, amp = 1.0f, norm = 0.0f;
            for (unsigned o = 0; o < 4; o++) {
                unsigned xi = (unsigned)x;
                unsigned yi = (unsigned)y;
                float xf = x - (float)xi;
                float yf = y - (float)yi;
                unsigned X = xi & 255;
                unsigned Y = yi & 255;
                unsigned aa = perm[perm[X] + Y];
                unsigned ab = perm[perm[X] + Y + 1];
                unsigned ba = perm[perm[X + 1] + Y];
                unsigned bb = perm[perm[X + 1] + Y + 1];
                float u = fade(xf);
                float v = fade(yf);
                float n = lerp(v, lerp(u, grad(aa, xf, yf), grad(ba, xf - 1.0f, yf)),
                               lerp(u, grad(ab, xf, yf - 1.0f), grad(bb, xf - 1.0f, yf - 1.0f)));
                sum = sum + n * amp;
                norm = norm + amp;
                amp = amp * 0.5f;
                x = x * 2.0f;
                y = y * 2.0f;
            }
            float s = (sum / norm) * 0.5f + 0.5f;
            if (s < 0.0f)
                s = 0.0f;
            if (s > 1.0f)
                s = 1.0f;
            unsigned p = (unsigned)(s * 255.0f);
            img[i] = (unsigned char)p;
            total = total + p;
        }
        bench_keep(total);
        long long t1 = bench_now_us();
        if (rep == 0)
            first = t1 - t0;
        if (rep == 0 || t1 - t0 < best)
            best = t1 - t0;
    }
    unsigned tenths = (total * 10 + (SIZE / 2)) / SIZE;
    printf("%u %lld %lld\n", tenths, best, first);
    return 0;
}
