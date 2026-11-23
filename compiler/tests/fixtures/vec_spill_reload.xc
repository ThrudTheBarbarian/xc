// A spilled vector reloaded after a vector write to its scratch register
// (#601): six pairs of run-time splats in a vectorised loop spill on arm64,
// and each read reloads its splat into v31. The reload-elimination peephole
// took `dup v31.4s, …` for a write to some other register, kept believing v31
// held the first spilled splat, and dropped the later reloads, so the loop
// multiplied by the wrong constants.
#import "Stdio.xc"
#define N 4096
u32 xs[N];
u32 run(u32 seed)
    {
    for (u32 i in 0..N)
        xs[i] = i * (u32)2654435761 + seed;
    u32 k0 = seed * (u32)3 + (u32)1;
    u32 k1 = seed * (u32)5 + (u32)2;
    u32 k2 = seed * (u32)7 + (u32)3;
    u32 k3 = seed * (u32)11 + (u32)4;
    u32 k4 = seed * (u32)13 + (u32)5;
    u32 k5 = seed * (u32)17 + (u32)6;
    u32 k6 = seed * (u32)19 + (u32)7;
    u32 k7 = seed * (u32)23 + (u32)8;
    u32 k8 = seed * (u32)29 + (u32)9;
    u32 k9 = seed * (u32)31 + (u32)10;
    u32 k10 = seed * (u32)37 + (u32)11;
    u32 k11 = seed * (u32)41 + (u32)12;
    u32 total = (u32)0;
    for (u32 i in 0..N)
        {
        u32 x = xs[i];
        total = total + ((x * k0) ^ k1) + ((x * k2) ^ k3) + ((x * k4) ^ k5) + ((x * k6) ^ k7) + ((x * k8) ^ k9) + ((x * k10) ^ k11);
        }
    return total;
    }
i32 main(void)
    {
    Stdio.printf("%u %u\n", run((u32)1), run((u32)7));
    return 0;
    }
