// mandel_deep as a plain loop: the par benchmark with its `par` block removed, for
// --par-auto (benchmark/par/auto/run.sh). Otherwise the same program.
// mandel_deep — a deliberately compute-heavy escape-time iteration that also
// writes its result, so a second GPU can help. Two things have to be true for
// the tile queue to spread a block across cards: the block must be big enough
// that the per-tile cost is amortised (the light `mandelbrot` finishes in about
// a millisecond, far too little), and it must move per-item data, because the
// queue cuts tiles by the bytes they move — a block that only reduces to a
// scalar is one tile, and one tile runs on one GPU. So this renders a 4096x4096
// iteration-count image (a 64 MB array it writes) at up to 4096 iterations,
// over a window biased onto the set's body so most pixels run the full count:
// uniform, heavy work with data to tile. One item per pixel. Prints
// "<checksum> <best_us> <first_us>"; the checksum is the total iteration count
// to the nearest million, coarse enough that fast GPU maths cannot move it.
#import "Stdio.xc"
#import "Par.xc"
#import "../../src/include/bench_time.xc"

#ifndef W
#define W 4096
#endif
#ifndef MAXITER
#define MAXITER 4096
#endif
#define SIZE (W * W)

u32 counts[SIZE];

i32 main(void)
{
    u32 total = (u32)0;
    i64 best = (i64)0;
    i64 first = (i64)0;
    for (u32 rep in 0..8)
    {
        total = (u32)0;
        i64 t0 = bench_now_us();
        for (u32 i in 0..SIZE)
        {
            // The window [-1.5, 0.0] x [-0.75, 0.75]: most pixels are inside
            // the set and so run the full iteration count.
            float cx = (float)(i % (u32)W) * (1.5f / (float)W) - 1.5f;
            float cy = (float)(i / (u32)W) * (1.5f / (float)W) - 0.75f;
            float x = 0.0f;
            float y = 0.0f;
            u32 k = (u32)0;
            while (k < (u32)MAXITER && x * x + y * y < 4.0f)
            {
                float xt = x * x - y * y + cx;
                y = 2.0f * x * y + cy;
                x = xt;
                k = k + (u32)1;
            }
            counts[i] = k;
            total = total + k;
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
