// par_f4.xc — par blocks writing f4 arrays, two elements to a byte. Each
// chunk of the range starts on the parity that keeps every byte on one
// thread: even for a[i] (1001 items, an odd count, so equal cuts fall on odd
// items), odd for b[i + 1]. A global, a captured local and a heap array,
// each checked element by element against a serial loop, over several runs.
// The blocks have no GPU form and run on the CPU's threads.
//xtc-na: xt6502, m68k — par has no threads there
//xtc-warn: runs on the CPU only, because it computes in f16, bf16, f8 or f4
#define ENABLE_64BIT 1
#import "Stdio.xc"
#import "Foundation.xc"
#import "Par.xc"

f4 ga[1001];

f4 want(u32 i, u32 r)
{
    return (f4)((f32)(i32)((i * 7 + r) % 13) - 6.0);
}

u32 check(f4[] a, u32 off, u32 n, u32 r)
{
    u32 bad = 0;
    for (u32 i = 0; i < n; i++)
        if (a[i + off] != want(i, r))
            bad++;
    return bad;
}

i32 main(void)
{
    u32 n = 1001;
    u32 bad = 0;
    f4 loc[1003];
    f4[] h = new f4[1001];
    for (u32 r = 0; r < 4; r++)
        {
        par
            {
            for (u32 i in 0..n)
                ga[i] = want(i, r);
            }
        bad = bad + check(ga, 0, n, r);
        par
            {
            for (u32 i in 0..n)
                loc[i + 1] = want(i, r);
            }
        bad = bad + check(loc, 1, n, r);
        par
            {
            for (u32 i in 0..n)
                h[i] = want(i, r);
            }
        bad = bad + check(h, 0, n, r);
        }
    Stdio.printf("bad %d\n", (i16)bad);
    return 0;
}
