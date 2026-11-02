// piv_step_tail.xc — int_muldiv's loop: a vectorised, unrolled reduction over
// a[i] inside an outer loop. Its pointer's step comes after the loads, so the
// pointer and its next value share a register (2026-11-02).
#import "Stdio.xc"

#define N 1024
u32 a[N];

i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++)
        a[i] = (i * (u32)2654435761) + seed;
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)20; r++)
        for (u32 i = (u32)0; i < (u32)N; i++)
            acc = acc + ((a[i] * (u32)7) / (u32)3) + (a[i] / (u32)11);
    Stdio.printf("%u\n", acc);
    return 0;
    }
