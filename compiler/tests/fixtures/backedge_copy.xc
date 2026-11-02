// backedge_copy.xc — array_map's loop: c[i] = a[i] + b[i] * 7 + r, vectorised
// and unrolled. The counter and its next value share a register, so the loop
// closes with one conditional branch and no copy (2026-11-02).
#import "Stdio.xc"

#define N 4096
u32 a[N];
u32 b[N];
u32 c[N];

i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++)
        {
        a[i] = i + seed;
        b[i] = (i * (u32)3) + seed;
        }
    for (u32 r = (u32)0; r < (u32)50; r++)
        for (u32 i = (u32)0; i < (u32)N; i++)
            c[i] = a[i] + (b[i] * (u32)7) + r;
    u32 acc = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        acc = acc + c[i];
    Stdio.printf("%u\n", acc);
    return 0;
    }
