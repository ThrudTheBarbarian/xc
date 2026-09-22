// mem_copy — copy between arrays element by element.
// Exercises: load/store pairing, the memcpy idiom, pointer induction.
#import "Stdio.xc"
#import "include/bench_time.xc"
#define N 4096
i32 main(i32 argc, u8** argv)
    {
    u32 src[N]; u32 dst[N];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++) src[i] = i + seed;
    u32 acc = (u32)0;
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)6800000; r++)
        {
        for (u32 i = (u32)0; i < (u32)N; i++) dst[i] = src[i] + r;
        acc = acc + dst[r % (u32)N];
        }
    i64 t1 = bench_now_us();
    Stdio.printf("%lu %lld\n", acc, t1 - t0);
    return 0;
    }
