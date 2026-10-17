//xtc-flags: target=arm64
// par_guard_interval.xc — the run-time checks par-check leaves where the
// static test cannot decide: a read and a write with unequal strides and a
// captured offset, and a read and a write each offset by a different
// captured integer. Where the elements written and read are disjoint the
// block runs in parallel; where they meet it runs serially, as its source
// reads. Every result is checked against a plain loop.
#import "Stdio.xc"
#import "Par.xc"
#define N 50000
u32 a[4 * N];
u32 s[4 * N];

void reset(void)
    {
    for (u32 i = (u32)0; i < (u32)(4 * N); i = i + (u32)1)
        {
        a[i] = i * (u32)7 + (u32)1;
        s[i] = a[i];
        }
    }

bool same(void)
    {
    for (u32 i = (u32)0; i < (u32)(4 * N); i = i + (u32)1)
        if (a[i] != s[i])
            return false;
    return true;
    }

i32 main(void)
    {
    // unequal strides: writes 2i, reads i + off
    u32 offs[2];
    offs[0] = (u32)(2 * N);     // disjoint
    offs[1] = (u32)3;           // overlapping
    for (u32 t = (u32)0; t < (u32)2; t = t + (u32)1)
        {
        reset();
        u32 off = offs[t];
        par strides
            {
            for (u32 i in 0..N)
                a[(u32)2 * i] = a[i + off] + (u32)1;
            }
        for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1)
            s[(u32)2 * i] = s[i + off] + (u32)1;
        Stdio.printf("strides off=%u same=%d\n", off, (i32)(same() ? 1 : 0));
        }
    // a different captured integer on each side: writes i + w, reads i + r
    u32 ws[2];
    ws[0] = (u32)(2 * N);       // far apart
    ws[1] = (u32)5;             // five apart
    for (u32 t = (u32)0; t < (u32)2; t = t + (u32)1)
        {
        reset();
        u32 w = ws[t];
        u32 r = (u32)0;
        par shifts
            {
            for (u32 i in 0..N)
                a[i + w] = a[i + r] * (u32)3;
            }
        for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1)
            s[i + w] = s[i + r] * (u32)3;
        Stdio.printf("shifts w=%u same=%d\n", w, (i32)(same() ? 1 : 0));
        }
    return 0;
    }
