// f16_convert_int.xc — f16 and bf16 to and from integers, and literals,
// checked bit for bit against an independent model that rounds the exact value
// to nearest even. An integer converts with one rounding, also from 64 bits;
// a conversion to an integer is toward zero, saturates at the type's range,
// and gives 0 for a NaN. A literal is rounded from its digits. 64-bit values
// print as four 16-bit groups, one per line, so every target's printf shows
// them the same way.
#define ENABLE_64BIT 1
#import "Stdio.xc"

u16 hbits(f16 h) { return *(u16*)&h; }
u16 bbits(bf16 g) { return *(u16*)&g; }
f16 hfrom(u16 u) { return *(f16*)&u; }
bf16 bfrom(u16 u) { return *(bf16*)&u; }
f32 ffrom(u32 u) { return *(f32*)&u; }

void put32(f32 f)
{
    u32 u = *(u32*)&f;
    Stdio.printf(" %x:%x", (u16)(u >> 16), (u16)u);
}

i32 INTS[20] = {0, 1, -1, 2048, 2049, 2050, 2051, 2052, 2053, 65504, 65519, 65520, -65520, 256, 257, 258, 259, 2147483647, -2147483647 - 1, 100000};
i64 I64[6] = {(i64)9223372036854775807, (i64)-9223372036854775807 - (i64)1, (i64)72339069014638592, (i64)72339069014638593, (i64)72902018968059904, (i64)1099511627776};
u16 SAT16[17] = {$0000, $8000, $3C00, $BC00, $3E00, $BE00, $7BFF, $FBFF, $7C00, $FC00, $7E00, $FE00, $5BF8, $57F8, $D800, $0001, $4C00};
u16 SATB[15] = {$3F80, $BFC0, $7F7F, $FF7F, $7F80, $FF80, $7FC0, $4F00, $4F80, $CF00, $5F00, $5F80, $DF00, $4780, $477F};

void put64(u64 v)
{
    Stdio.printf("%x:%x:%x:%x\n", (u16)(v >> 48), (u16)(v >> 32), (u16)(v >> 16), (u16)v);
}

void sat(f16 h)
{
    Stdio.printf("%d %u %d %u", (i16)(i8)h, (u16)(u8)h, (i16)h, (u16)h);
    Stdio.printf("\n");
    put64((u64)(i64)(i32)h);
    put64((u64)(u32)h);
}

void satb(bf16 g)
{
    Stdio.printf("%d %u", (i16)(i8)g, (u16)g);
    Stdio.printf("\n");
    put64((u64)(i64)(i32)g);
    put64((u64)(u32)g);
    put64((u64)(i64)g);
    put64((u64)g);
}

i32 main(void)
{
    Stdio.printf("int\n");
    for (u32 i = 0; i < 20; i++)
        Stdio.printf("%x %x %x\n", hbits((f16)INTS[i]), bbits((bf16)INTS[i]), bbits((bf16)(u32)INTS[i]));
    for (u32 i = 0; i < 6; i++)
        Stdio.printf("%x %x %x\n", hbits((f16)I64[i]), bbits((bf16)I64[i]), bbits((bf16)(u64)I64[i]));
    Stdio.printf("saturate\n");
    for (u32 i = 0; i < 17; i++)
        sat(hfrom(SAT16[i]));
    for (u32 i = 0; i < 15; i++)
        satb(bfrom(SATB[i]));
    Stdio.printf("literal\n");
    f16 lmax = 65504.0;
    f16 lsub = 0.000000059604645;
    f16 ltie = 2049;
    f16 lneg = -0.0;
    bf16 bmax = 3.3895e38;
    bf16 btie = 257;
    bf16 bsub = 9.2e-41;
    Stdio.printf("%x %x %x %x\n", hbits(lmax), hbits(lsub), hbits(ltie), hbits(lneg));
    Stdio.printf("%x %x %x\n", bbits(bmax), bbits(btie), bbits(bsub));
    f16 hnan = hfrom($7E00);
    bf16 bnan = bfrom($7FC0);
    f16 hinf = (f16)ffrom($7F800000);
    Stdio.printf("print %f %f\n", lmax, ltie);
    Stdio.printf("nan %x %x widen %x\n", hbits(hnan * 2), bbits(bnan + 1), hbits((f16)(bf16)hnan));
    Stdio.printf("inf %x %x\n", hbits(hinf), hbits(-hinf));
    return 0;
}
