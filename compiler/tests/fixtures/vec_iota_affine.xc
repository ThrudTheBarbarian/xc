// vec_iota_affine.xc — map loops whose stored value is an affine function of
// the induction variable, i * K + D: sort_small's fill
// `a[i] = ((i * K) ^ (r * K2)) + s`, a signed i * K - D, (i - 3) * K, two
// constants in a row, a trip that leaves a scalar remainder and one that
// starts at 5. The vectoriser keeps (i + l) * K in a vector stepped by an add,
// so the loops' bodies have no vector multiply; 4 * K wraps for every K here.
#import "Stdio.xc"

#define N 64
#define M 103
u32 a[N];
i32 b[M];
u32 c[N];
u32 d[N];
u32 e[M];

void fill(u32 r, u32 seed)
    {
    for (u32 i = (u32)0; i < (u32)N; i++)
        a[i] = ((i * (u32)2654435761) ^ (r * (u32)40503)) + seed;
    }

void signed_affine(i32 k)
    {
    for (i32 i = 0; i < (i32)M; i++)
        b[i] = i * (i32)-1640531527 - (i32)12345 + k;
    }

void sub_mul(void)
    {
    for (u32 i = (u32)0; i < (u32)N; i++)
        c[i] = (i - (u32)3) * (u32)3266489917;
    }

void two_muls(u32 x)
    {
    for (u32 i = (u32)0; i < (u32)N; i++)
        d[i] = (i * (u32)668265263) * (u32)374761393 ^ x;
    }

void late_start(u32 x)
    {
    for (u32 i = (u32)5; i < (u32)M; i++)
        e[i] = i * (u32)2246822519 + x;
    }

i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc;
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)3; r++)
        {
        fill(r, seed);
        signed_affine((i32)r);
        sub_mul();
        two_muls(r);
        late_start(r);
        for (u32 i = (u32)0; i < (u32)N; i++)
            acc = acc * (u32)31 + a[i] + c[i] + d[i];
        for (u32 i = (u32)0; i < (u32)M; i++)
            acc = acc * (u32)31 + (u32)b[i] + e[i];
        }
    Stdio.printf("%u %u %d %u %u %u %u\n", acc, a[N - 1], b[M - 1], c[0], d[N - 1], e[5], e[M - 1]);
    return 0;
    }
