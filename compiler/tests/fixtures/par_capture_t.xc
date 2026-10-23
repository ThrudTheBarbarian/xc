//xtc-flags: target=arm64
//xtc-na: xt6502 m68k arm9 — par needs threads
// A par block may capture a variable called t. The block's copyChunk() made
// its new chunk in a local `t`, which shadowed the capture: `t.t = t` stored
// the chunk itself, and a float* capture failed to build ("a class reference
// 'ParImpl$0*' is not a raw 'float*'").
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
    return 0;
    }
