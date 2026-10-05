// mandelbrot — escape-time iteration counts over a 2048x2048 grid, one item
// per pixel: arithmetic only, with a data-dependent loop. Prints
// "<checksum> <best_us> <first_us>"; the checksum is the total iteration count to
// the nearest million, coarse enough that fast GPU maths cannot move it.
#import "Stdio.xc"
#import "Par.xc"
#import "../src/include/bench_time.xc"

#define W 2048
#define SIZE (2048 * 2048)

i32 main(void)
{
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
        par mandel :reduce(+ total)
        {
            for (u32 i in 0..SIZE)
            {
                float cx = (float)(i % (u32)W) * (3.0f / 2048.0f) - 2.0f;
                float cy = (float)(i / (u32)W) * (3.0f / 2048.0f) - 1.5f;
                float x = 0.0f;
                float y = 0.0f;
                u32 k = (u32)0;
                while (k < (u32)256 && x * x + y * y < 4.0f)
                {
                    float xt = x * x - y * y + cx;
                    y = 2.0f * x * y + cy;
                    x = xt;
                    k = k + (u32)1;
                }
                total = total + k;
            }
        }
        i64 t1 = bench_now_us();
        if (rep == (u32)0)
            first = t1 - t0;
        if (rep == (u32)0 || t1 - t0 < best)
            best = t1 - t0;
    }
    Stdio.printf("%u %lld %lld\n", (total + (u32)500000) / (u32)1000000, best, first);
    return 0;
}
