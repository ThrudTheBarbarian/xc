// int_muldiv — integer multiply and divide by compile-time constants.
// Exercises: strength reduction, magic-number division. The divided value
// changes every pass (a[i] + r), so no pass can be skipped; the version where
// it does not is int_muldiv_hoist.
#import "Stdio.xc"
#import "include/bench_time.xc"
#define N 1024
i32 main(i32 argc, u8** argv)
    {
    u32 a[N];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++) a[i] = (i * (u32)2654435761) + seed;
    u32 acc = (u32)0;
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)6800000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++)
            {
            u32 v = a[i] + r;
            acc = acc + ((v * (u32)7) / (u32)3) + (v / (u32)11);
            }
    i64 t1 = bench_now_us();
    Stdio.printf("%lu %lld\n", acc, t1 - t0);
    return 0;
    }
