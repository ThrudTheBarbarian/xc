// call_depth — a small non-inlinable call chain in a hot loop.
// Exercises: call overhead, leaf inlining, tail-call conversion.
#import "Stdio.xc"
#import "include/bench_time.xc"

u32 leaf(u32 x)  { return (x * (u32)3) ^ (x >> (u32)2); }
u32 mid(u32 x)   { return leaf(x) + leaf(x + (u32)1); }
u32 outer(u32 x) { return mid(x) ^ mid(x + (u32)2); }

i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc;
    u32 acc  = (u32)0;
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)2800000000; r++) acc = acc + outer(r + seed);
    i64 t1 = bench_now_us();
    Stdio.printf("%lu %lld\n", acc, t1 - t0);
    return 0;
    }
