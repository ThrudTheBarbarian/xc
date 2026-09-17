// sort_small — insertion sort of a small array, repeatedly.
// Exercises: nested loops, data-dependent branches, swaps.
#import "Stdio.xc"
#import "include/bench_time.xc"
#define N 64
i32 main(i32 argc, u8** argv)
    {
    u32 a[N]; u32 seed = (u32)argc; u32 acc = (u32)0;
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)40000; r++)
        {
        for (u32 i = (u32)0; i < (u32)N; i++)
            a[i] = ((i * (u32)2654435761) ^ (r * (u32)40503)) + seed;
        for (u32 i = (u32)1; i < (u32)N; i++)
            {
            u32 v = a[i]; u32 j = i;
            while (j > (u32)0 && a[j - (u32)1] > v) { a[j] = a[j - (u32)1]; j = j - (u32)1; }
            a[j] = v;
            }
        acc = acc + a[0] + a[N - 1];
        }
    i64 t1 = bench_now_us();
    Stdio.printf("%lu %lld\n", acc, t1 - t0);
    return 0;
    }
