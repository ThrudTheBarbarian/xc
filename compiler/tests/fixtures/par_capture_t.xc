//xtc-flags: target=arm64
//xtc-na: xt6502 m68k arm9 — par needs threads
// A par block may capture a variable called t. The block's copyChunk() made
// its new chunk in a local `t`, which shadowed the capture: `t.t = t` stored
// the chunk itself, so a float* capture failed to build ("a class reference
// 'ParImpl$0*' is not a raw 'float*'") and a scalar one was silently wrong in
// every CPU chunk after the first (a block's first run is on the CPU).
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
    {
    u32 n = (u32)1000;
    float* t = new float[n];
    float* other = new float[n];
    for (u32 i in 0..n)
        t[i] = (float)i;
    par copyIt
        {
        for (u32 i in 0..n)
            other[i] = t[i] * 2.0f;
        }
    float s = 0.0f;
    for (u32 i in 0..n)
        s = s + other[i];
    Stdio.printf("%.1f\n", (double)s);

    u32 m = (u32)65536;
    float* out = new float[m];
    float tval = 2.0f;
    {
    float t = tval;
    par fill
        {
        for (u32 i in 0..m)
            out[i] = t;
        }
    }
    u32 wrong = (u32)0;
    for (u32 i in 0..m)
        if (out[i] != 2.0f)
            wrong = wrong + (u32)1;
    Stdio.printf("scalar t: %u wrong\n", wrong);
    return 0;
    }
