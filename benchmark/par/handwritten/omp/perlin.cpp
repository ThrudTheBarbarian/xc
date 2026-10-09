// perlin — benchmark/par/perlin.xc written by hand with OpenMP.
// Same data, same arithmetic, same eight runs, same checksum. CPU only.
#include <stdio.h>
#include <stdint.h>
#include "../../../src/include/bench_time.h"

#define SIZE (2048 * 2048)

static uint32_t perm[512];
static uint8_t img[SIZE];

static float fade(float t) { return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f); }
static float lerp(float t, float a, float b) { return a + t * (b - a); }
static float grad(uint32_t h, float x, float y)
{
    uint32_t g = h & 7u;
    float u = g < 4u ? x : y;
    float v = g < 4u ? y : x;
    float a = (g & 1u) ? -u : u;
    float b = (g & 2u) ? -2.0f * v : 2.0f * v;
    return a + b;
}

int main(void)
{
    uint32_t seed = 12345;
    for (uint32_t i = 0; i < 256; i++)
        perm[i] = i;
    for (uint32_t i = 0; i < 256; i++)
    {
        seed = seed * 1103515245u + 12345u;
        uint32_t j = i + (seed >> 16) % (256u - i);
        uint32_t t = perm[i];
        perm[i] = perm[j];
        perm[j] = t;
    }
    for (uint32_t i = 0; i < 256; i++)
        perm[i + 256] = perm[i];

    uint32_t total = 0;
    int64_t best = 0, first = 0;
    for (uint32_t rep = 0; rep < 8; rep++)
    {
        total = 0;
        int64_t t0 = bench_now_us();
        #pragma omp parallel for reduction(+:total) schedule(static)
        for (uint32_t i = 0; i < SIZE; i++)
        {
            float x = (float)(i % 2048u) / 256.0f;
            float y = (float)(i / 2048u) / 256.0f;
            float sum = 0.0f, amp = 1.0f, norm = 0.0f;
            for (uint32_t o = 0; o < 4; o++)
            {
                uint32_t xi = (uint32_t)x, yi = (uint32_t)y;
                float xf = x - (float)xi, yf = y - (float)yi;
                uint32_t X = xi & 255u, Y = yi & 255u;
                uint32_t aa = perm[perm[X] + Y];
                uint32_t ab = perm[perm[X] + Y + 1u];
                uint32_t ba = perm[perm[X + 1u] + Y];
                uint32_t bb = perm[perm[X + 1u] + Y + 1u];
                float u = fade(xf), v = fade(yf);
                float n = lerp(v, lerp(u, grad(aa, xf, yf), grad(ba, xf - 1.0f, yf)),
                               lerp(u, grad(ab, xf, yf - 1.0f), grad(bb, xf - 1.0f, yf - 1.0f)));
                sum = sum + n * amp;
                norm = norm + amp;
                amp = amp * 0.5f;
                x = x * 2.0f;
                y = y * 2.0f;
            }
            float s = (sum / norm) * 0.5f + 0.5f;
            if (s < 0.0f) s = 0.0f;
            if (s > 1.0f) s = 1.0f;
            uint32_t p = (uint32_t)(s * 255.0f);
            img[i] = (uint8_t)p;
            total += p;
        }
        int64_t t1 = bench_now_us();
        if (rep == 0) first = t1 - t0;
        if (rep == 0 || t1 - t0 < best) best = t1 - t0;
    }
    printf("%u %lld %lld\n", (total * 10u + (SIZE / 2)) / SIZE,
           (long long)best, (long long)first);
    return 0;
}
