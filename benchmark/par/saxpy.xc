// saxpy — y = a*x + y over 16M integers: one multiply-add per element and
// two arrays to move, so memory, not arithmetic, sets the pace. On a GPU the
// copies in and out cost more than the work: this is the block auto keeps on
// the CPU. Prints "<checksum> <best_us> <first_us>"; the checksum is exact.
#import "Stdio.xc"
#import "Par.xc"
#import "../src/include/bench_time.xc"

#define SIZE (16 * 1024 * 1024)

u32 xs[SIZE];
u32 ys[SIZE];

i32 main(void)
{
    for (u32 i in 0..SIZE)
    {
        xs[i] = i * (u32)2654435761;
        ys[i] = i;
    }
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
        par saxpy :reduce(+ total)
        {
            for (u32 i in 0..SIZE)
            {
                u32 v = (u32)3 * xs[i] + ys[i];
                ys[i] = v;
                total = total + v;
            }
        }
        i64 t1 = bench_now_us();
        if (rep == (u32)0)
            first = t1 - t0;
        if (rep == (u32)0 || t1 - t0 < best)
            best = t1 - t0;
    }
    Stdio.printf("%u %lld %lld\n", total, best, first);
    return 0;
}
