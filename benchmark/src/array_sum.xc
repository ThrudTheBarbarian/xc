// array_sum — sum an array. Exercises: reduction loop, array addressing.
// This is the shape the arm64 reduction vectoriser recognises.
#import "Stdio.xc"
#define N 4096
i32 main(i32 argc, u8** argv)
    {
    u32 a[N];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++) a[i] = (i * (u32)2654435761) + seed;
    u32 sum = (u32)0;
    for (u32 r = (u32)0; r < (u32)20000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++) sum = sum + a[i];
    Stdio.printf("%lu\n", sum);
    return 0;
    }
