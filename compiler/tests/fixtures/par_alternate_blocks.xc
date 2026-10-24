// Two par blocks run in turn over their own arrays, and the host changes one
// between runs (2026-10-24, CUDA residency): a GPU keeps each block's array
// resident (CUDA parks a slot's copy when another block takes the slot), and
// a copy the host has written since must go up again, not be reused. The
// answers are the serial loops' on every device.
#import "Stdio.xc"
#import "Par.xc"
#define N (1024 * 1024)
i32 main(void)
    {
    u32* xs = new u32[N];
    u32* ys = new u32[N];
    for (u32 i in 0..N) { xs[i] = i; ys[i] = i * (u32)3; }
    u32 bad = (u32)0;
    for (u32 rep in 0..6)
        {
        if (rep == (u32)3)
            for (u32 i in 0..N) xs[i] = xs[i] + (u32)1;   // written between runs
        u32 ta = (u32)0;
        par suma :reduce(+ ta)
            {
            for (u32 i in 0..N) ta = ta + xs[i] * (u32)7;
            }
        u32 tb = (u32)0;
        par sumb :reduce(+ tb)
            {
            for (u32 i in 0..N) tb = tb + ys[i] * (u32)5;
            }
        u32 sa = (u32)0;
        u32 sb = (u32)0;
        for (u32 i in 0..N) { sa = sa + xs[i] * (u32)7; sb = sb + ys[i] * (u32)5; }
        if (ta != sa || tb != sb) bad = bad + (u32)1;
        }
    Stdio.printf("runs 6, wrong %u\n", bad);
    return 0;
    }
