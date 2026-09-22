// array_sum — sum an array. Exercises: reduction loop, array addressing.
// This is the shape the arm64 reduction vectoriser recognises.
#import "Stdio.xc"
#import "include/bench_time.xc"
#define N 4096
i32 main(i32 argc, u8** argv)
    {
    u32 a[N];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++) a[i] = (i * (u32)2654435761) + seed;
    u32 sum = (u32)0;
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)7000000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++) sum = sum + a[i];
    i64 t1 = bench_now_us();
    Stdio.printf("%lu %lld\n", sum, t1 - t0);
    return 0;
    }
