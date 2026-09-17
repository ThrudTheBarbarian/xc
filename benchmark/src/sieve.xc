// sieve — sieve of Eratosthenes over a fixed range, repeatedly.
// Exercises: byte array writes, strided inner loops, division-free stepping.
#import "Stdio.xc"
#import "include/bench_time.xc"
#define N 8192
i32 main(i32 argc, u8** argv)
    {
    u8 flags[N]; u32 seed = (u32)argc; u32 acc = (u32)0;
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)2000; r++)
        {
        for (u32 i = (u32)0; i < (u32)N; i++) flags[i] = (u8)1;
        u32 count = (u32)0;
        for (u32 i = (u32)2; i < (u32)N; i++)
            if (flags[i] != (u8)0)
                {
                count = count + (u32)1;
                for (u32 j = i + i; j < (u32)N; j = j + i) flags[j] = (u8)0;
                }
        acc = acc + count + (r & seed);
        }
    i64 t1 = bench_now_us();
    Stdio.printf("%lu %lld\n", acc, t1 - t0);
    return 0;
    }
