// Vectorised loops whose start is not a literal (2026-10-21): the vector loop
// runs from the start to start + ((bound - start) & ~(vw-1)) and a scalar
// remainder finishes. Every start from 0 to 20 against bounds below, at and
// past it (7, 16, 1000), for a map, a sum and a loop that does both, checked
// against the scalar answer (the released compiler kept these loops scalar).
#import "Stdio.xc"
#define N 1000
u32 xs[N];
u32 ys[N];
u32 run(u32 s, u32 b, u32 kind)
    {
    for (u32 i in 0..N) { xs[i] = i * (u32)2654435761; ys[i] = i * (u32)7; }
    u32 total = (u32)0;
    if (kind == (u32)0)
        {
        for (u32 i = s; i < b; i++)
            ys[i] = (u32)3 * xs[i] + ys[i];
        }
    else if (kind == (u32)1)
        {
        for (u32 i = s; i < b; i++)
            total = total + xs[i];
        }
    else
        {
        for (u32 i = s; i < b; i++)
            {
            u32 v = (u32)3 * xs[i] + ys[i];
            ys[i] = v;
            total = total + v;
            }
        }
    u32 h = total;
    for (u32 i in 0..N)
        h = h * (u32)31 + ys[i];
    return h;
    }
i32 main(i32 argc, u8** argv)
    {
    u32 bounds[3];
    bounds[0] = (u32)7;
    bounds[1] = (u32)16;
    bounds[2] = (u32)N;
    for (u32 k in 0..3)
        {
        u32 acc = (u32)0;
        for (u32 bi in 0..3)
            for (u32 s in 0..21)
                acc = acc * (u32)1000003 + run(s, bounds[bi], k);
        Stdio.printf("kind %u: %u\n", k, acc);
        }
    return 0;
    }
