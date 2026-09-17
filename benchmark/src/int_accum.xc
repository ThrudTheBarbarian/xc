// int_accum — integer add and xor over an array.
// Exercises: loop induction, array addressing, u32 wraparound arithmetic.
//
// The array is seeded from argc so its contents are unknown at compile time,
// and the loop reads it every iteration. Without that both compilers reduce the
// whole loop to a closed form and the benchmark measures nothing.
#import "Stdio.xc"
#import "include/bench_time.xc"

#define N 4096

i32 main(i32 argc, u8** argv)
    {
    u32 a[N];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++)
        a[i] = (i * (u32)2654435761) + seed;

    u32 acc = (u32)0;
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)20000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++)
            acc = acc + (a[i] ^ acc);

    i64 t1 = bench_now_us();

    Stdio.printf("%lu %lld\n", acc, t1 - t0);
    return 0;
    }
