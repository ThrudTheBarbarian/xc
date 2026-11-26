// f4_convert.xc — f4 (OCP MX FP4, e2m1: one sign bit, two exponent bits,
// one mantissa bit, no infinity or NaN) converted from f64 and f32 and back,
// bit for bit. The expected patterns come from an independent model that
// rounds the exact value to nearest even: all 16 patterns decode, ties
// (0.25 to 0, 0.75 to 1, 1.25 to 1, 1.75 to 2, 2.5 to 2, 3.5 to 4, 5 to 4),
// saturation (7, 100 and an infinity to 6), NaN to +0, and -0. Then the
// exact widening of every pattern to f8, f8:pack(e5m2), f16 and bf16 with
// no cast, the casts back from every f8 pattern, and literals rounded at
// compile time.
#define ENABLE_64BIT 1
#import "Stdio.xc"

u16 b4(f4 x)
{
    u8* p = (u8*)&x;
    return (u16)p[0];
}

f4 f4of(u16 b)
{
    u8 v = (u8)b;
    f4[] r = (f4[])&v;
    return r[0];
}

f8 f8of(u16 b)
{
    u8 v = (u8)b;
    return *(f8*)&v;
}

u16 b8(f8 x) { return (u16)*(u8*)&x; }
u16 b8e(f8:pack(e5m2) x) { return (u16)*(u8*)&x; }
u16 b16(f16 x) { return *(u16*)&x; }
u16 bbf(bf16 x) { return *(u16*)&x; }
f32 ffrom(u32 u) { return *(f32*)&u; }

f64 D[32] = {0.0d, -0.0d, 0.25d, 0.75d, 1.25d, 1.75d, 2.5d, 3.5d, 5.0d, 7.0d, 100.0d, 1e999d, -1e999d, 0.0d, 0.5d, 6.0d, 5.999d, 6.5d, 6.9999d, -0.75d, -2.5d, -5.0d, -7.0d, -1e+30d, 0.2499999d, 0.25000001d, 0.7499999d, 1e-300d, 4.5d, 2.75d, 1.4999d, 3.25d};
u32 F[24] = {$00000000, $80000000, $7F800000, $FF800000, $7FC00000, $FFC00000, $7F800001, $3E800000, $3F400000, $3FA00000, $3FE00000, $40200000, $40600000, $40A00000, $40E00000, $42C80000, $3E7FFFFF, $3E800001, $40C00000, $C0C00000, $C0600000, $00000001, $40DFFFFF, $40E00000};

void decode(void)
{
    Stdio.printf("decode\n");
    for (u16 b = 0; b < 16; b++)
        {
        f32 f = f4of(b);
        u32 u = *(u32*)&f;
        Stdio.printf("%x:%x", (u16)(u >> 16), (u16)u);
        if (b % 4 == 3)
            Stdio.printf("\n");
        else
            Stdio.printf(" ");
        }
}

void fromF64(void)
{
    Stdio.printf("f64\n");
    for (u32 i = 0; i < 32; i++)
        {
        f64 d = D[i];
        if (i == 13)
            d = d - d;
        Stdio.printf("%x", b4((f4)d));
        if (i % 16 == 15)
            Stdio.printf("\n");
        }
}

void fromF32(void)
{
    Stdio.printf("f32\n");
    for (u32 i = 0; i < 24; i++)
        {
        Stdio.printf("%x", b4((f4)ffrom(F[i])));
        if (i % 16 == 15)
            Stdio.printf("\n");
        }
    Stdio.printf("\n");
}


void widen(void)
{
    Stdio.printf("widen\n");
    for (u16 b = 0; b < 16; b++)
        {
        f4 x = f4of(b);
        f8 e = x;
        f8:pack(e5m2) g = x;
        f16 hh = x;
        bf16 k = x;
        Stdio.printf("%x %x", b8(e), b8e(g));
        Stdio.printf(" %x %x\n", b16(hh), bbf(k));
        }
}

void narrow(void)
{
    Stdio.printf("from f8\n");
    for (u16 b = 0; b < 256; b++)
        {
        Stdio.printf("%x", b4((f4)f8of(b)));
        if (b % 32 == 31)
            Stdio.printf("\n");
        }
}

void literals(void)
{
    Stdio.printf("literals\n");
    f4 l0 = 0.25;
    f4 l1 = 0.75;
    f4 l2 = 1.25;
    f4 l3 = 1.75;
    f4 l4 = 2.5;
    f4 l5 = 3.5;
    f4 l6 = 5.0;
    f4 l7 = 6.0;
    f4 l8 = 6.9;
    f4 l9 = -6.9;
    f4 l10 = 0.1;
    f4 l11 = -0.0;
    f4 l12 = 3;
    f4 l13 = -4;
    Stdio.printf("%x %x %x %x %x %x %x", b4(l0), b4(l1), b4(l2), b4(l3), b4(l4), b4(l5), b4(l6));
    Stdio.printf("\n%x %x %x %x %x %x %x\n", b4(l7), b4(l8), b4(l9), b4(l10), b4(l11), b4(l12), b4(l13));
}

i32 main(void)
{
    decode();
    fromF64();
    fromF32();
    widen();
    narrow();
    literals();
    return 0;
}
