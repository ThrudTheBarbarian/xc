// vec_map_iota.xc — a map loop that stores a value computed from its own
// induction variable (sort_small's fill, 2026-11-02): `a[i] = ((i * K) ^ x) + s`
// with no load, `b[i] = a[i] + i` with one, and a trip that leaves a scalar
// remainder. Lane l of the vectorised iv holds i + l.
#import "Stdio.xc"

#define N 64
#define M 103
u32 a[N];
u32 b[N];
u32 c[M];

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
            acc = acc + (a[i] ^ b[i]);
        for (u32 i = (u32)0; i < (u32)M; i++)
            acc = acc + c[i];
        }
    Stdio.printf("%u %u %u %u\n", acc, a[N - 1], b[5], c[M - 1]);
    return 0;
    }
