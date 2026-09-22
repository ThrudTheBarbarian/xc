// float_math — float multiply, accumulated in double.
// Exercises: float arithmetic, multiply-add fusion, float register pressure.
//
// Values are small exact integers and the accumulator is double, so the sum is
// exact whatever order the additions happen in. A vectorising compiler reorders
// them, and without exactness the two languages would disagree on rounding.
#import "Stdio.xc"
#import "include/bench_time.xc"
#define N 4096
i32 main(i32 argc, u8** argv)
    {
    float a[N]; float b[N];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++)
        { a[i] = (float)((i + seed) % (u32)16); b[i] = (float)((i % (u32)7) + (u32)1); }
    double acc = 0.0;
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)400000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++)
            acc = acc + (double)(a[i] * b[i]);
    i64 t1 = bench_now_us();
    // (u32)acc directly is UNDEFINED once the sum exceeds u32: at this
    // iteration count acc reaches ~4.9e10, and the two compilers chose
    // differently (0 against 4294967295). The double is still exact — well
    // under 2^53 — so going through u64 and letting the u32 narrowing wrap,
    // which IS defined, keeps the checksum meaningful and identical.
    Stdio.printf("%lu %lld\n", (u32)((u64)acc), t1 - t0);
    return 0;
    }
