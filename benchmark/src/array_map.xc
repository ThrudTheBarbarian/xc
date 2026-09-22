// array_map — elementwise c[i] = a[i] + b[i] * k.
// Exercises: elementwise map loop, the shape the arm64 map vectoriser takes.
#import "Stdio.xc"
#import "include/bench_time.xc"
#define N 4096
i32 main(i32 argc, u8** argv)
    {
    u32 a[N]; u32 b[N]; u32 c[N];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++)
        { a[i] = i + seed; b[i] = (i * (u32)3) + seed; }
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)5000000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++)
            c[i] = a[i] + (b[i] * (u32)7) + r;
    u32 acc = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++) acc = acc + c[i];
    i64 t1 = bench_now_us();
    Stdio.printf("%lu %lld\n", acc, t1 - t0);
    return 0;
    }
