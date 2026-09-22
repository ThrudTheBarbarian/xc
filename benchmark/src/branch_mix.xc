// branch_mix — data-dependent branches over an array.
// Exercises: if-conversion, select formation, branch prediction behaviour.
#import "Stdio.xc"
#import "include/bench_time.xc"
#define N 4096
i32 main(i32 argc, u8** argv)
    {
    u32 a[N];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++) a[i] = (i * (u32)2654435761) + seed;
    u32 acc = (u32)0;
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)500000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++)
            {
            if ((a[i] & (u32)1) == (u32)0) acc = acc + a[i];
            else                           acc = acc ^ a[i];
            }
    i64 t1 = bench_now_us();
    Stdio.printf("%lu %lld\n", acc, t1 - t0);
    return 0;
    }
