// branch_mix — data-dependent branches over an array.
// Exercises: if-conversion, select formation, branch prediction behaviour.
#import "Stdio.xc"
#define N 4096
i32 main(i32 argc, u8** argv)
    {
    u32 a[N];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++) a[i] = (i * (u32)2654435761) + seed;
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)20000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++)
            {
            if ((a[i] & (u32)1) == (u32)0) acc = acc + a[i];
            else                           acc = acc ^ a[i];
            }
    Stdio.printf("%lu\n", acc);
    return 0;
    }
