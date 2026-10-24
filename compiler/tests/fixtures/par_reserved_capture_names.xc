// A block may capture, or reduce into, a variable named as one of the block's
// own members (lo, hi, run, merge, go, ...): each was refused ("the name is
// one of the block's own"). The capture keeps its name in the body; its field
// in the block's class is renamed. Each answer is checked against a loop.
#import "Stdio.xc"
#import "Par.xc"
u64 sumMod(u32 n, u32 lo)
    {
    u64 total = (u64)0;
    par sum :reduce(+ total)
        {
        for (u32 i in 0..n)
            total = total + (u64)(i % lo);
        }
    return total;
    }

i32 main(void)
    {
    u32 n = (u32)5000;
    simd: float* d = new float[n];
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        d[i] = (float)((i * (u32)37) % (u32)1001) - (float)500.0;

    // A reduction called lo, and one called hi.
    float lo = (float)1.0e30;
    float hi = (float)-1.0e30;
    par extremes :reduce(min lo) :reduce(max hi)
        {
        for (u32 i in 0..n)
            {
            if (d[i] < lo) lo = d[i];
            if (d[i] > hi) hi = d[i];
            }
        }
    float wlo = (float)1.0e30;
    float whi = (float)-1.0e30;
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        {
        if (d[i] < wlo) wlo = d[i];
        if (d[i] > whi) whi = d[i];
        }

    // Captures called run (a pointer), merge (a scalar) and go (a scalar).
    simd: float* run = new float[n];
    float merge = (float)2.0;
    u32 go = (u32)3;
    par scale
        {
        for (u32 i in 0..n)
            run[i] = d[i] * merge + (float)go;
        }
    u32 bad = (u32)0;
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        if (run[i] != d[i] * (float)2.0 + (float)3.0)
            bad = bad + (u32)1;

    // A scalar capture called lo: the block's range must still start at
    // its own lo (0 here), not at the capture's value.
    u64 total = sumMod(n, (u32)7);
    u64 want = (u64)0;
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        want = want + (u64)(i % (u32)7);

    Stdio.printf("lo %s, hi %s, scaled wrong %u, sum %s\n",
                  lo == wlo ? "ok" : "WRONG", hi == whi ? "ok" : "WRONG", bad,
                  total == want ? "ok" : "WRONG");
    return 0;
    }
