// f8_convert.xc — conversions to the 8-bit float packs from f32 and f64,
// and back to f32, checked bit for bit: f8 (OCP E4M3, finite), f8:pack(e5m2)
// (OCP E5M2, ieee), f8:pack(ue8m0) (the unsigned scale), and a custom pack of
// each kind: e3m4 (ieee), e5m2,finite and e2m5,none. The expected patterns
// come from an independent model that rounds the exact value to nearest even
// with each kind's overflow and NaN rules. The cases cover the largest
// finite value, overflow (saturating where the pack has no infinity, an
// infinity where it has one), the smallest normal, the smallest and largest
// subnormals, ties to even, signed zeros and NaN. The way back is checked
// over all 256 patterns of each pack, as a checksum of the f32 bits.
#define ENABLE_64BIT 1
#import "Stdio.xc"

u16 b0(f8 x) { return (u16)*(u8*)&x; }
u16 b1(f8:pack(e5m2) x) { return (u16)*(u8*)&x; }
u16 b2(f8:pack(ue8m0) x) { return (u16)*(u8*)&x; }
u16 b3(f8:pack(e3m4) x) { return (u16)*(u8*)&x; }
u16 b4(f8:pack(e5m2, finite) x) { return (u16)*(u8*)&x; }
u16 b5(f8:pack(e2m5, none) x) { return (u16)*(u8*)&x; }
f32 ffrom(u32 u) { return *(f32*)&u; }

u32 F32[72] = {$00000000, $80000000, $7F800000, $FF800000, $7FC00000, $FFC00000, $7F800001, $7FA00000, $43E00000, $43E80000, $43E80001, $43F00000, $447A0000, $3C800000, $3C600000, $3B000000, $3A800000, $3A800001, $C3E00000, $3F880000, $3F980000, $BF880000, $41880000, $41980000, $47600000, $47700000, $476FFF00, $38800000, $37800000, $38400000, $37000000, $37000001, $3F900000, $3FB00000, $BFB00000, $7F000000, $7F400000, $7F600000, $00400000, $00200000, $40400000, $40C00000, $3F400000, $C0000000, $3F800000, $41780000, $417C0000, $3C800000, $47C00000, $47E00000, $40FC0000, $41000000, $3DCCCCCD, $3EAAAAAB, $40490FDB, $C0200000, $42C80000, $3E99999A, $B658F7A7, $317017A6, $39CEB3A1, $8FAF0010, $399B1548, $07C15471, $34007CB4, $92B850AD, $949D0AC1, $3C2F7AD0, $051E2670, $B92A5FBA, $A6EDAF80, $B9DB434B};
f64 F64[20] = {0.1d, 448.0d, 464.0d, 464.00000000001d, 479.99999999999994d, 57344.0d, 61440.0d, 61439.999999999d, 0.001953125d, 0.0009765625d, 0.0009765625000000009d, 1.0625d, 2.5521177519070385e+38d, 1e-300d, -2.5d, 1e+300d, 15.75d, 98303.99999999999d, 7.9375d, 3.0d};

void put(u32 u)
{
    Stdio.printf("%x:%x\n", (u16)(u >> 16), (u16)u);
}

void from32(void)
{
    Stdio.printf("f32\n");
    for (u32 i = 0; i < 72; i++)
    {
        f32 f = ffrom(F32[i]);
        Stdio.printf("%x %x %x", b0((f8)f), b1((f8:pack(e5m2))f), b2((f8:pack(ue8m0))f));
        Stdio.printf(" %x %x %x\n", b3((f8:pack(e3m4))f), b4((f8:pack(e5m2, finite))f),
                     b5((f8:pack(e2m5, none))f));
    }
}

void from64(void)
{
    Stdio.printf("f64\n");
    for (u32 i = 0; i < 20; i++)
    {
        f64 d = F64[i];
        Stdio.printf("%x %x %x", b0((f8)d), b1((f8:pack(e5m2))d), b2((f8:pack(ue8m0))d));
        Stdio.printf(" %x %x %x\n", b3((f8:pack(e3m4))d), b4((f8:pack(e5m2, finite))d),
                     b5((f8:pack(e2m5, none))d));
    }
}

f32 v0(u32 p)
{
    u8 b = (u8)p;
    return *(f8*)&b;
}

void back0(void)
{
    u32 s = 0;
    for (u32 p = 0; p < 256; p++)
    {
        f32 f = v0(p);
        s = s * 31 + *(u32*)&f;
    }
    put(s);
}

f32 v1(u32 p)
{
    u8 b = (u8)p;
    return *(f8:pack(e5m2)*)&b;
}

void back1(void)
{
    u32 s = 0;
    for (u32 p = 0; p < 256; p++)
    {
        f32 f = v1(p);
        s = s * 31 + *(u32*)&f;
    }
    put(s);
}

f32 v2(u32 p)
{
    u8 b = (u8)p;
    return *(f8:pack(ue8m0)*)&b;
}

void back2(void)
{
    u32 s = 0;
    for (u32 p = 0; p < 256; p++)
    {
        f32 f = v2(p);
        s = s * 31 + *(u32*)&f;
    }
    put(s);
}

f32 v3(u32 p)
{
    u8 b = (u8)p;
    return *(f8:pack(e3m4)*)&b;
}

void back3(void)
{
    u32 s = 0;
    for (u32 p = 0; p < 256; p++)
    {
        f32 f = v3(p);
        s = s * 31 + *(u32*)&f;
    }
    put(s);
}

f32 v4(u32 p)
{
    u8 b = (u8)p;
    return *(f8:pack(e5m2, finite)*)&b;
}

void back4(void)
{
    u32 s = 0;
    for (u32 p = 0; p < 256; p++)
    {
        f32 f = v4(p);
        s = s * 31 + *(u32*)&f;
    }
    put(s);
}

f32 v5(u32 p)
{
    u8 b = (u8)p;
    return *(f8:pack(e2m5, none)*)&b;
}

void back5(void)
{
    u32 s = 0;
    for (u32 p = 0; p < 256; p++)
    {
        f32 f = v5(p);
        s = s * 31 + *(u32*)&f;
    }
    put(s);
}

void samples(void)
{
    // A few patterns of each, written out.
    u32 P[6] = {$01, $08, $7E, $7F, $80, $FE};
    for (u32 i = 0; i < 6; i++)
    {
        f32 a = v0(P[i]);
        f32 b = v1(P[i]);
        f32 c = v2(P[i]);
        Stdio.printf("%x ", (u16)P[i]);
        put(*(u32*)&a);
        Stdio.printf("  ");
        put(*(u32*)&b);
        Stdio.printf("  ");
        put(*(u32*)&c);
    }
}

i32 main(void)
{
    from32();
    from64();
    Stdio.printf("back\n");
    back0();
    back1();
    back2();
    back3();
    back4();
    back5();
    samples();
    return 0;
}
