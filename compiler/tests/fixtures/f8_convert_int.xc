// f8_convert_int.xc — the 8-bit float packs to and from integers, and
// literals, checked bit for bit against an independent model that rounds the
// exact value to nearest even with each kind's overflow rule: f8 (E4M3),
// f8:pack(e5m2), f8:pack(ue8m0) and a custom pack of each kind. An integer
// converts with one rounding, also from 64 bits, and one beyond a pack's range
// saturates (no infinity) or becomes an infinity (ieee). A conversion to an
// integer is toward zero, saturates at the type's range and gives 0 for a
// NaN. 64-bit values print as four 16-bit groups.
#define ENABLE_64BIT 1
#import "Stdio.xc"

u16 b0(f8 x) { return (u16)*(u8*)&x; }
f8 p0(u16 u) { u8 v = (u8)u; return *(f8*)&v; }
u16 b1(f8:pack(e5m2) x) { return (u16)*(u8*)&x; }
f8:pack(e5m2) p1(u16 u) { u8 v = (u8)u; return *(f8:pack(e5m2)*)&v; }
u16 b2(f8:pack(ue8m0) x) { return (u16)*(u8*)&x; }
f8:pack(ue8m0) p2(u16 u) { u8 v = (u8)u; return *(f8:pack(ue8m0)*)&v; }
u16 b3(f8:pack(e3m4) x) { return (u16)*(u8*)&x; }
f8:pack(e3m4) p3(u16 u) { u8 v = (u8)u; return *(f8:pack(e3m4)*)&v; }
u16 b4(f8:pack(e5m2, finite) x) { return (u16)*(u8*)&x; }
f8:pack(e5m2, finite) p4(u16 u) { u8 v = (u8)u; return *(f8:pack(e5m2, finite)*)&v; }
u16 b5(f8:pack(e2m5, none) x) { return (u16)*(u8*)&x; }
f8:pack(e2m5, none) p5(u16 u) { u8 v = (u8)u; return *(f8:pack(e2m5, none)*)&v; }

i32 INTS[29] = {0, 1, -1, 7, 8, 9, 15, 17, 18, 19, 21, 448, 449, 464, 465, 480, 1000, -1000, 57344, 61439, 61440, 65536, 3, 6, 2147483647, -2147483647 - 1, 100000, 23, 25};
u32 U32[3] = {$FFFFFFFF, $B2D05E00, $80000000};
i64 I64[6] = {(i64)9223372036854775807, (i64)-9223372036854775807 - (i64)1, (i64)5188146770730811392, (i64)4899916394579099648, (i64)4899916394579099649, (i64)1099511627776};

void put64(u64 v)
{
    Stdio.printf("%x:%x:%x:%x\n", (u16)(v >> 48), (u16)(v >> 32), (u16)(v >> 16), (u16)v);
}

void fromInts(void)
{
    Stdio.printf("int\n");
    for (u32 i = 0; i < 29; i++)
    {
        i32 v = INTS[i];
        Stdio.printf("%x %x %x", b0((f8)v), b1((f8:pack(e5m2))v), b2((f8:pack(ue8m0))v));
        Stdio.printf(" %x %x %x\n", b3((f8:pack(e3m4))v), b4((f8:pack(e5m2, finite))v), b5((f8:pack(e2m5, none))v));
    }
    for (u32 i = 0; i < 3; i++)
    {
        u32 u = U32[i];
        Stdio.printf("%x %x %x", b0((f8)u), b1((f8:pack(e5m2))u), b2((f8:pack(ue8m0))u));
        Stdio.printf(" %x %x %x\n", b3((f8:pack(e3m4))u), b4((f8:pack(e5m2, finite))u), b5((f8:pack(e2m5, none))u));
    }
    for (u32 i = 0; i < 6; i++)
    {
        i64 w = I64[i];
        u64 uw = (u64)w;
        Stdio.printf("%x %x %x", b0((f8)w), b1((f8:pack(e5m2))w), b2((f8:pack(ue8m0))w));
        Stdio.printf(" %x %x %x\n", b3((f8:pack(e3m4))uw), b4((f8:pack(e5m2, finite))uw), b2((f8:pack(ue8m0))uw));
    }
}

u16 S0[14] = {$00, $80, $38, $B8, $7E, $FE, $7F, $FF, $01, $3C, $BC, $5F, $63, $6F};

void sat0(void)
{
    for (u32 i = 0; i < 14; i++)
    {
        f8 x = p0(S0[i]);
        Stdio.printf("%d %u %d %u\n", (i16)(i8)x, (u16)(u8)x, (i16)x, (u16)x);
        put64((u64)(i64)(i32)x);
        put64((u64)(u32)x);
        put64((u64)(i64)x);
        put64((u64)x);
    }
}

u16 S1[12] = {$7B, $FB, $7C, $FC, $7E, $3D, $BE, $58, $5C, $60, $64, $02};

void sat1(void)
{
    for (u32 i = 0; i < 12; i++)
    {
        f8:pack(e5m2) x = p1(S1[i]);
        Stdio.printf("%d %u %d %u\n", (i16)(i8)x, (u16)(u8)x, (i16)x, (u16)x);
        put64((u64)(i64)(i32)x);
        put64((u64)(u32)x);
        put64((u64)(i64)x);
        put64((u64)x);
    }
}

u16 S2[12] = {$FE, $7F, $7E, $9E, $9F, $BE, $BF, $FF, $00, $86, $8E, $8F};

void sat2(void)
{
    for (u32 i = 0; i < 12; i++)
    {
        f8:pack(ue8m0) x = p2(S2[i]);
        Stdio.printf("%d %u %d %u\n", (i16)(i8)x, (u16)(u8)x, (i16)x, (u16)x);
        put64((u64)(i64)(i32)x);
        put64((u64)(u32)x);
        put64((u64)(i64)x);
        put64((u64)x);
    }
}

u16 S3[8] = {$6F, $EF, $70, $F0, $78, $3C, $BC, $01};

void sat3(void)
{
    for (u32 i = 0; i < 8; i++)
    {
        f8:pack(e3m4) x = p3(S3[i]);
        Stdio.printf("%d %u %d %u\n", (i16)(i8)x, (u16)(u8)x, (i16)x, (u16)x);
        put64((u64)(i64)(i32)x);
        put64((u64)(u32)x);
        put64((u64)(i64)x);
        put64((u64)x);
    }
}

u16 S4[6] = {$7E, $FE, $7F, $FF, $7C, $5C};

void sat4(void)
{
    for (u32 i = 0; i < 6; i++)
    {
        f8:pack(e5m2, finite) x = p4(S4[i]);
        Stdio.printf("%d %u %d %u\n", (i16)(i8)x, (u16)(u8)x, (i16)x, (u16)x);
        put64((u64)(i64)(i32)x);
        put64((u64)(u32)x);
        put64((u64)(i64)x);
        put64((u64)x);
    }
}

u16 S5[6] = {$7F, $FF, $60, $E0, $30, $01};

void sat5(void)
{
    for (u32 i = 0; i < 6; i++)
    {
        f8:pack(e2m5, none) x = p5(S5[i]);
        Stdio.printf("%d %u %d %u\n", (i16)(i8)x, (u16)(u8)x, (i16)x, (u16)x);
        put64((u64)(i64)(i32)x);
        put64((u64)(u32)x);
        put64((u64)(i64)x);
        put64((u64)x);
    }
}

void literals(void)
{
    f8 l0 = 448.0;
    f8 l1 = 0.001953125;
    f8 l2 = 17;
    f8 l3 = -0.0;
    f8 l4 = 464;
    f8 l5 = -0.1;
    f8:pack(e5m2) l6 = 57344.0;
    f8:pack(e5m2) l7 = 61439.0;
    f8:pack(e5m2) l8 = 0.0000152587890625;
    f8:pack(e5m2) l9 = -1.125;
    f8:pack(ue8m0) l10 = 0.25;
    f8:pack(ue8m0) l11 = 3;
    f8:pack(ue8m0) l12 = 1.7014118346046923e38;
    f8:pack(ue8m0) l13 = 6.0;
    f8:pack(e3m4) l14 = 15.5;
    f8:pack(e5m2, finite) l15 = 98304.0;
    f8:pack(e2m5, none) l16 = 7.875;
    f8:pack(e2m5, none) l17 = -0.03125;
    Stdio.printf("%x\n", b0(l0));
    Stdio.printf("%x\n", b0(l1));
    Stdio.printf("%x\n", b0(l2));
    Stdio.printf("%x\n", b0(l3));
    Stdio.printf("%x\n", b0(l4));
    Stdio.printf("%x\n", b0(l5));
    Stdio.printf("%x\n", b1(l6));
    Stdio.printf("%x\n", b1(l7));
    Stdio.printf("%x\n", b1(l8));
    Stdio.printf("%x\n", b1(l9));
    Stdio.printf("%x\n", b2(l10));
    Stdio.printf("%x\n", b2(l11));
    Stdio.printf("%x\n", b2(l12));
    Stdio.printf("%x\n", b2(l13));
    Stdio.printf("%x\n", b3(l14));
    Stdio.printf("%x\n", b4(l15));
    Stdio.printf("%x\n", b5(l16));
    Stdio.printf("%x\n", b5(l17));
}

i32 main(void)
{
    fromInts();
    Stdio.printf("saturate\n");
    sat0();
    sat1();
    sat2();
    sat3();
    sat4();
    sat5();
    Stdio.printf("literal\n");
    literals();
    return 0;
}
