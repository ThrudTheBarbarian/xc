// chain — four elementwise steps over 16M integers, then their sum, each step
// a par block of its own (#147): xcc runs adjacent blocks that need only what
// the one before wrote at the same index as one block, so each item's
// intermediates stay in registers and there is one launch, not four. Built
// with -fno-par-fuse, the steps run apart, for comparison. Prints
// "<checksum> <best_us> <first_us>"; the checksum is exact.
#import "Stdio.xc"
#import "Par.xc"
#import "../src/include/bench_time.xc"

#define SIZE (16 * 1024 * 1024)

u32 xs[SIZE];
u32 as[SIZE];
u32 bs[SIZE];
u32 cs[SIZE];

i32 main(void)
{
    for (u32 i in 0..SIZE)
        xs[i] = i * (u32)2654435761;
    u32 total = (u32)0;
    i64 best = (i64)0;
    i64 first = (i64)0;
    for (u32 rep in 0..8)
    {
        total = (u32)0;
        i64 t0 = bench_now_us();
        par mix
        {
            for (u32 i in 0..SIZE)
                as[i] = xs[i] * (u32)3 + (u32)7;
        }
        par shift
        {
            for (u32 i in 0..SIZE)
                bs[i] = (as[i] >> (u32)3) ^ xs[i];
        }
        par blend
        {
            for (u32 i in 0..SIZE)
                cs[i] = bs[i] * as[i] + (u32)1;
        }
        par sum :reduce(+ total)
        {
            for (u32 i in 0..SIZE)
                total = total + (cs[i] ^ (cs[i] >> (u32)7));
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
