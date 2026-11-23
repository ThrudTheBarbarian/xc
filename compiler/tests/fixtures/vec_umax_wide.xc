// vec_umax_wide — an unsigned max and min over lanes on both sides of 2^31,
// where the signed instruction gives the other answer. On arm9 these loops are
// `vmax.u32`/`vmin.u32`, which the assembler used to encode as the SIGNED
// vmax.s32/vmin.s32.
#import "Stdio.xc"

u32 g[64];

i32 main(void)
    {
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1)
        g[i] = (i & (u32)1) == (u32)0 ? (u32)$7FFFFFF0 - i : (u32)$80000010 + i;
    u32 hi = (u32)0;
    u32 lo = (u32)$FFFFFFFF;
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) if (g[i] > hi) hi = g[i];
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) if (g[i] < lo) lo = g[i];
    Stdio.printf("max %08x min %08x\n", hi, lo);
    return 0;
    }
