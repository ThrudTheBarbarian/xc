// int_muldiv — integer multiply and divide by compile-time constants.
// Exercises: strength reduction, magic-number division.
#import "Stdio.xc"
#define N 1024
i32 main(i32 argc, u8** argv)
    {
    u32 a[N];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++) a[i] = (i * (u32)2654435761) + seed;
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)40000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++)
            acc = acc + ((a[i] * (u32)7) / (u32)3) + (a[i] / (u32)11);
    Stdio.printf("%lu\n", acc);
    return 0;
    }
