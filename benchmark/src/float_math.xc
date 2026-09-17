// float_math — float multiply, accumulated in double.
// Exercises: float arithmetic, multiply-add fusion, float register pressure.
//
// Values are small exact integers and the accumulator is double, so the sum is
// exact whatever order the additions happen in. A vectorising compiler reorders
// them, and without exactness the two languages would disagree on rounding.
#import "Stdio.xc"
#define N 4096
i32 main(i32 argc, u8** argv)
    {
    float a[N]; float b[N];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++)
        { a[i] = (float)((i + seed) % (u32)16); b[i] = (float)((i % (u32)7) + (u32)1); }
    double acc = 0.0;
    for (u32 r = (u32)0; r < (u32)4000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++)
            acc = acc + (double)(a[i] * b[i]);
    Stdio.printf("%lu\n", (u32)acc);
    return 0;
    }
