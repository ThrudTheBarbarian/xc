// vec_map_iota.xc — map loops that store a value computed from their own
// induction variable: `a[i] = ((i * K) ^ x) + s` (sort_small's fill) and
// `p[i] = i`, `e[i] = i + 5`, `s[i] = (i32)i` with no load, `b[i] = a[i] + i`
// with one, a trip that leaves a scalar remainder, and one that starts at 3;
// and a constant of 2^31 or more in a vectorised map. Lane l of the
// vectorised iv holds i + l.
#import "Stdio.xc"

#define N 64
#define M 103
u32 a[N];
u32 b[N];
u32 c[M];
u32 d[N];
u32 p[N];
u32 e[M];
i32 s[N];
u32 f[M];

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
            p[i] = i;
        for (u32 i = (u32)0; i < (u32)M; i++)
            e[i] = i + (u32)5;
        for (u32 i = (u32)0; i < (u32)N; i++)
            s[i] = (i32)i - (i32)7;
        for (u32 i = (u32)3; i < (u32)M; i++)
            f[i] = i ^ r;
        for (u32 i = (u32)0; i < (u32)N; i++)
            acc = acc + p[i] * (u32)3 + (u32)s[i];
        for (u32 i = (u32)0; i < (u32)M; i++)
            acc = acc + e[i] + f[i] * (u32)5;
        for (u32 i = (u32)0; i < (u32)N; i++)
            acc = acc + (a[i] ^ b[i]) + d[i];
        for (u32 i = (u32)0; i < (u32)M; i++)
            acc = acc + c[i];
        }
    Stdio.printf("%u %u %u %u %u %u %d %u\n", acc, a[N - 1], b[5], c[M - 1], p[N - 1], e[M - 1], s[0], f[3]);
    return 0;
    }
