// soft_float_rn.xc — the correctly rounded float division and square root a
// `par` accuracy block uses on Vulkan and WebGPU (ParSoftFloat.xc), against
// the CPU's own instructions: edge values, then random pairs biased to
// subnormals and nearby exponents. Any NaN matches any NaN.
//xtc-na: xt6502, m68k, arm9 — no IEEE single-precision hardware to compare with
#import "Stdio.xc"
#import "ParSoftFloat.xc"
#import "Math.xc"
u32 rng = (u32)12345;
u32 next(void) { rng = rng ^ (rng << (u32)13); rng = rng ^ (rng >> (u32)17); rng = rng ^ (rng << (u32)5); return rng; }
i32 main(void)
    {
    u32 bad = (u32)0;
    u32 n = (u32)0;
    u32 edge[16];
    edge[0] = (u32)0; edge[1] = (u32)0x80000000; edge[2] = (u32)1; edge[3] = (u32)0x7FFFFF; edge[4] = (u32)0x800000;
    edge[5] = (u32)0x7F7FFFFF; edge[6] = (u32)0x7F800000; edge[7] = (u32)0xFF800000; edge[8] = (u32)0x7FC00000;
    edge[9] = (u32)0x3F800000; edge[10] = (u32)0x40000000; edge[11] = (u32)0x00400001; edge[12] = (u32)0x3F7FFFFF;
    edge[13] = (u32)0x80000001; edge[14] = (u32)0x7F000000; edge[15] = (u32)0x01000000;
    for (u32 i = (u32)0; i < (u32)300000; i = i + (u32)1)
        {
        u32 x = next();
        u32 y = next();
        if (i < (u32)256) { x = edge[i & (u32)15]; y = edge[i >> (u32)4]; }
        else if ((i & (u32)7) == (u32)0) { x = x & (u32)0x807FFFFF; }     // subnormal x
        else if ((i & (u32)7) == (u32)1) { y = y & (u32)0x807FFFFF; }
        else if ((i & (u32)7) == (u32)2) { x = (x & (u32)0x81FFFFFF) | (u32)0x3E000000; y = (y & (u32)0x81FFFFFF) | (u32)0x7C000000; }
        float a = xcF32FromBits(x);
        float b = xcF32FromBits(y);
        u32 h = xcF32Bits(a / b);
        u32 s = xcF32Bits(xcFdivRn(a, b));
        bool hn = (h & (u32)0x7FFFFFFF) > (u32)0x7F800000;
        bool sn = (s & (u32)0x7FFFFFFF) > (u32)0x7F800000;
        if (!(h == s || (hn && sn)))
            {
            if (bad < (u32)8) Stdio.printf("div %08x / %08x: hw %08x soft %08x\n", x, y, h, s);
            bad = bad + (u32)1;
            }
        u32 hq = xcF32Bits(Math.sqrt(a));
        u32 sq = xcF32Bits(xcFsqrtRn(a));
        hn = (hq & (u32)0x7FFFFFFF) > (u32)0x7F800000;
        sn = (sq & (u32)0x7FFFFFFF) > (u32)0x7F800000;
        if (!(hq == sq || (hn && sn)))
            {
            if (bad < (u32)16) Stdio.printf("sqrt %08x: hw %08x soft %08x\n", x, hq, sq);
            bad = bad + (u32)1;
            }
        n = n + (u32)1;
        }
    Stdio.printf("%u pairs, %u mismatches\n", n, bad);
    return (i32)0;
    }
