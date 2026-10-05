// perlin — Ken Perlin's improved noise, 2D, four octaves, over a 2048x2048
// image: a permutation table read at data-dependent places, helper calls,
// and one store per pixel. Prints "<checksum> <best_us> <first_us>"; the checksum is
// the mean grey level to a tenth.
#import "Stdio.xc"
#import "Par.xc"
#import "../src/include/bench_time.xc"

#define SIZE (2048 * 2048)

u32 perm[512];
u8 img[SIZE];

float fade(float t) { return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f); }
float lerp(float t, float a, float b) { return a + t * (b - a); }
float grad(u32 h, float x, float y)
{
    u32 g = h & (u32)7;
    float u = g < (u32)4 ? x : y;
    float v = g < (u32)4 ? y : x;
    float a = (g & (u32)1) != (u32)0 ? 0.0f - u : u;
    float b = (g & (u32)2) != (u32)0 ? 0.0f - 2.0f * v : 2.0f * v;
    return a + b;
}

i32 main(void)
{
    u32 seed = (u32)12345;
    for (u32 i in 0..256)
        perm[i] = i;
    for (u32 i in 0..256)
    {
        seed = seed * (u32)1103515245 + (u32)12345;
        u32 j = i + (seed >> (u32)16) % ((u32)256 - i);
        u32 t = perm[i];
        perm[i] = perm[j];
        perm[j] = t;
    }
    for (u32 i in 0..256)
        perm[i + (u32)256] = perm[i];

    // Eight runs: the first carries one-off costs (a GPU builds its kernel
    // then), so the figure is the best run; the first is printed too. Auto
    // decides after its fourth (two on each device), and uses the rest.
    u32 total = (u32)0;
    i64 best = (i64)0;
    i64 first = (i64)0;
    for (u32 rep in 0..8)
    {
        total = (u32)0;
        i64 t0 = bench_now_us();
        par perlin :reduce(+ total)
        {
            for (u32 i in 0..SIZE)
            {
                float x = (float)(i % (u32)2048) / 256.0f;
                float y = (float)(i / (u32)2048) / 256.0f;
                float sum = 0.0f;
                float amp = 1.0f;
                float norm = 0.0f;
                for (u32 o in 0..4)
                {
                    u32 xi = (u32)x;
                    u32 yi = (u32)y;
                    float xf = x - (float)xi;
                    float yf = y - (float)yi;
                    u32 X = xi & (u32)255;
                    u32 Y = yi & (u32)255;
                    u32 aa = perm[perm[X] + Y];
                    u32 ab = perm[perm[X] + Y + (u32)1];
                    u32 ba = perm[perm[X + (u32)1] + Y];
                    u32 bb = perm[perm[X + (u32)1] + Y + (u32)1];
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
                u32 p = (u32)(s * 255.0f);
                img[i] = (u8)p;
                total = total + p;
            }
        }
        i64 t1 = bench_now_us();
        if (rep == (u32)0)
            first = t1 - t0;
        if (rep == (u32)0 || t1 - t0 < best)
            best = t1 - t0;
    }
    u32 tenths = (total * (u32)10 + (u32)(SIZE / 2)) / (u32)SIZE;
    Stdio.printf("%u %lld %lld\n", tenths, best, first);
    return 0;
}
