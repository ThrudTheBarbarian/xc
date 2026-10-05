// nbody — the gravitational force on each of 8192 bodies from all the others:
// O(n^2) arithmetic over small arrays, one item per body. Prints
// "<checksum> <best_us> <first_us>"; the checksum counts the bodies pulled right
// (positive x force), a coarse figure fast GPU maths does not move.
#import "Stdio.xc"
#import "Math.xc"
#import "Par.xc"
#import "../src/include/bench_time.xc"

#define N 8192

float px[N];
float py[N];
float mass[N];
float fx[N];

i32 main(void)
{
    u32 seed = (u32)7;
    for (u32 i in 0..N)
    {
        seed = seed * (u32)1664525 + (u32)1013904223;
        px[i] = (float)(seed >> (u32)8) / 16777216.0f;
        seed = seed * (u32)1664525 + (u32)1013904223;
        py[i] = (float)(seed >> (u32)8) / 16777216.0f;
        mass[i] = 1.0f + (float)(i % (u32)7);
    }
    // Eight runs: the first carries one-off costs (a GPU builds its kernel
    // then), so the figure is the best run; the first is printed too. Auto
    // decides after its fourth (two on each device), and uses the rest.
    u32 right = (u32)0;
    i64 best = (i64)0;
    i64 first = (i64)0;
    for (u32 rep in 0..8)
    {
        right = (u32)0;
        i64 t0 = bench_now_us();
        par forces :reduce(+ right)
        {
            for (u32 i in 0..N)
            {
                float ax = 0.0f;
                for (u32 j in 0..N)
                {
                    float dx = px[j] - px[i];
                    float dy = py[j] - py[i];
                    float d2 = dx * dx + dy * dy + 0.0001f;
                    ax = ax + mass[j] * dx / (d2 * Math.sqrt(d2));
                }
                fx[i] = ax;
                if (ax > 0.0f)
                    right = right + (u32)1;
            }
        }
        i64 t1 = bench_now_us();
        if (rep == (u32)0)
            first = t1 - t0;
        if (rep == (u32)0 || t1 - t0 < best)
            best = t1 - t0;
    }
    Stdio.printf("%u %lld %lld\n", (right + (u32)50) / (u32)100, best, first);
    return 0;
}
