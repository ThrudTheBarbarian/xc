// hash_mix — an integer avalanche chain.
// Exercises: multiply, shift and xor chains with a serial dependency.
#import "Stdio.xc"
#import "include/bench_time.xc"
i32 main(i32 argc, u8** argv)
    {
    u32 h = (u32)argc; 
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)640000000; r++)
        {
        h = h ^ (h >> (u32)16);
        h = h * (u32)2246822519;
        h = h ^ (h >> (u32)13);
        h = h + r;
        }
    i64 t1 = bench_now_us();
    Stdio.printf("%lu %lld\n", h, t1 - t0);
    return 0;
    }
