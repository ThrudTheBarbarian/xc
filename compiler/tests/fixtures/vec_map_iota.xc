// vec_map_iota.xc — map loops that store a value computed from their own
// induction variable (sort_small's fill, 2026-11-02): `a[i] = ((i * K) ^ x) + s`
// with no load, `b[i] = a[i] + i` with one, and a trip that leaves a scalar
// remainder; and a constant of 2^31 or more in a vectorised map. Not
// vectorised yet: a vector in a function costs the x86-64 back end every float
// home, so the map path keeps the iv out of its lanes for now.
#import "Stdio.xc"

#define N 64
#define M 103
u32 a[N];
u32 b[N];
u32 c[M];
u32 d[N];

i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc;
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)3; r++)
        {
        for (u32 i = (u32)0; i < (u32)N; i++)
            a[i] = ((i * (u32)2654435761) ^ (r * (u32)40503)) + seed;
        for (u32 i = (u32)0; i < (u32)N; i++)
            b[i] = a[i] + i;
        for (u32 i = (u32)0; i < (u32)M; i++)
            c[i] = i * (u32)7 + r;
        for (u32 i = (u32)0; i < (u32)N; i++)
            d[i] = a[i] * (u32)2654435761;
        for (u32 i = (u32)0; i < (u32)N; i++)
            acc = acc + (a[i] ^ b[i]) + d[i];
        for (u32 i = (u32)0; i < (u32)M; i++)
            acc = acc + c[i];
        }
    Stdio.printf("%u %u %u %u\n", acc, a[N - 1], b[5], c[M - 1]);
    return 0;
    }
