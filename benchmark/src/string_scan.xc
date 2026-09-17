// string_scan — scan bytes for a delimiter and checksum them.
// Exercises: byte loads, comparisons, narrow-type arithmetic.
#import "Stdio.xc"
#define N 8192
i32 main(i32 argc, u8** argv)
    {
    u8 buf[N]; u32 seed = (u32)argc; u32 acc = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        buf[i] = (u8)(((i * (u32)31) + seed) & (u32)127);
    for (u32 r = (u32)0; r < (u32)20000; r++)
        {
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < (u32)N; i++)
            { if (buf[i] == (u8)44) n = n + (u32)1; acc = acc + (u32)buf[i]; }
        acc = acc + n;
        }
    Stdio.printf("%lu\n", acc);
    return 0;
    }
