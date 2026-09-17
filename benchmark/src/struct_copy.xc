// struct_copy — pass and return a small struct by value.
// Exercises: struct copy semantics, field layout, argument passing.
#import "Stdio.xc"
#import "include/bench_time.xc"
struct Pt { u32 x, y; }
Pt bump(Pt p, u32 d) { Pt q; q.x = p.x + d; q.y = p.y ^ d; return q; }
i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc; u32 acc = (u32)0;
    Pt p; p.x = seed; p.y = seed;
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)4000000; r++)
        { p = bump(p, r); acc = acc + p.x + p.y; }
    i64 t1 = bench_now_us();
    Stdio.printf("%lu %lld\n", acc, t1 - t0);
    return 0;
    }
