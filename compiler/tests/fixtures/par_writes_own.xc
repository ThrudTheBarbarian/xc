// par_writes_own.xc — a captured array the block overwrites whole is not
// sent to the device (2026-10-25): its old contents are never read, so only
// its space is made there (gpuWritesAllOwn, as gpuWritesAll for a global).
// `whole` overwrites ys; `half` writes only the first half of zs, whose
// second half must keep its 5s; `reads` reads acc as it writes it. The
// runtime reports one array written whole.

#import "Stdio.xc"
#import "Par.xc"

#define N 4194304

i32 main(i32 argc, u8** argv)
    {
    float* xs = new float[N];
    float* ys = new float[N];
    float* zs = new float[N];
    float* acc = new float[N];
    for (u32 i = 0; i < N; i++)
        {
        xs[i] = (float)(i % 1000) * 0.25;
        ys[i] = -9.0;
        zs[i] = 5.0;
        acc[i] = 1.0;
        }
    par whole
        {
        for (u32 i in 0..N)
            ys[i] = xs[i] * 2.0 + 1.0;
        }
    par half
        {
        for (u32 i in 0..N / 2)
            zs[i] = xs[i];
        }
    par reads
        {
        for (u32 i in 0..N)
            acc[i] = acc[i] + xs[i];
        }
    double sy = 0.0;
    double sz = 0.0;
    double sa = 0.0;
    for (u32 i = 0; i < N; i++)
        {
        sy = sy + (double)ys[i];
        sz = sz + (double)zs[i];
        sa = sa + (double)acc[i];
        }
    Stdio.printf("%.1f %.1f %.1f\n", sy, sz, sa);
    return 0;
    }
