// f8_arith.xc — arithmetic in the 8-bit float packs: each operation works
// in f32 from exact operands and rounds once to the pack, which is the
// correctly rounded result, and a result beyond the pack's range saturates
// where it has no infinity (f8, ue8m0, the finite and none customs) and is an
// infinity where it has one. The expected patterns come from an independent
// model that computes each result exactly and rounds it. A NaN result prints
// as "nan" (its sign and payload depend on the machine's f32). Also:
// negation, ++ and --, compound assignment, comparisons with NaN and zeros,
// mixed arithmetic widening to the type that holds both operands, and printf.
#define ENABLE_64BIT 1
#import "Stdio.xc"

u16 b0(f8 x) { return (u16)*(u8*)&x; }
f8 p0(u16 u) { u8 v = (u8)u; return *(f8*)&v; }

void s0(f8 x)
{
    u16 b = b0(x);
    if ((b & $7F) == $7F)
        Stdio.printf(" nan");
    else
        Stdio.printf(" %x", b);
}

u16 A0[13] = {$38, $7E, $7E, $01, $3C, $38, $00, $7F, $38, $3E, $3F, $01, $08};
u16 B0[13] = {$30, $7E, $FE, $01, $3A, $00, $00, $38, $08, $30, $31, $80, $3C};

void ops0(void)
{
    for (u32 i = 0; i < 13; i++)
    {
        f8 a = p0(A0[i]);
        f8 c = p0(B0[i]);
        Stdio.printf("%x %x:", A0[i], B0[i]);
        s0(a + c);
        s0(a - c);
        s0(a * c);
        s0(a / c);
        Stdio.printf("\n");
    }
}

u16 b1(f8:pack(e5m2) x) { return (u16)*(u8*)&x; }
f8:pack(e5m2) p1(u16 u) { u8 v = (u8)u; return *(f8:pack(e5m2)*)&v; }

void s1(f8:pack(e5m2) x)
{
    u16 b = b1(x);
    if ((b & $7C) == $7C && (b & 3) != 0)
        Stdio.printf(" nan");
    else
        Stdio.printf(" %x", b);
}

u16 A1[12] = {$7B, $7C, $7C, $3C, $01, $3C, $3D, $7E, $FE, $2D, $C1, $19};
u16 B1[12] = {$7B, $FC, $00, $00, $01, $30, $39, $3C, $EB, $41, $11, $6C};

void ops1(void)
{
    for (u32 i = 0; i < 12; i++)
    {
        f8:pack(e5m2) a = p1(A1[i]);
        f8:pack(e5m2) c = p1(B1[i]);
        Stdio.printf("%x %x:", A1[i], B1[i]);
        s1(a + c);
        s1(a - c);
        s1(a * c);
        s1(a / c);
        Stdio.printf("\n");
    }
}

u16 b2(f8:pack(ue8m0) x) { return (u16)*(u8*)&x; }
f8:pack(ue8m0) p2(u16 u) { u8 v = (u8)u; return *(f8:pack(ue8m0)*)&v; }

void s2(f8:pack(ue8m0) x)
{
    u16 b = b2(x);
    if (b == $FF)
        Stdio.printf(" nan");
    else
        Stdio.printf(" %x", b);
}

u16 A2[12] = {$7F, $FE, $00, $81, $FF, $7E, $60, $9E, $1B, $4E, $9A, $F3};
u16 B2[12] = {$80, $FE, $00, $7F, $7F, $82, $59, $2A, $D2, $B4, $67, $75};

void ops2(void)
{
    for (u32 i = 0; i < 12; i++)
    {
        f8:pack(ue8m0) a = p2(A2[i]);
        f8:pack(ue8m0) c = p2(B2[i]);
        Stdio.printf("%x %x:", A2[i], B2[i]);
        s2(a + c);
        s2(a - c);
        s2(a * c);
        s2(a / c);
        Stdio.printf("\n");
    }
}

u16 b3(f8:pack(e3m4) x) { return (u16)*(u8*)&x; }
f8:pack(e3m4) p3(u16 u) { u8 v = (u8)u; return *(f8:pack(e3m4)*)&v; }

void s3(f8:pack(e3m4) x)
{
    u16 b = b3(x);
    if ((b & $70) == $70 && (b & $F) != 0)
        Stdio.printf(" nan");
    else
        Stdio.printf(" %x", b);
}

u16 A3[12] = {$6F, $01, $3C, $30, $E4, $16, $0A, $B2, $5F, $F4, $A4, $75};
u16 B3[12] = {$6F, $01, $35, $00, $55, $0F, $EE, $C5, $A2, $E8, $E1, $45};

void ops3(void)
{
    for (u32 i = 0; i < 12; i++)
    {
        f8:pack(e3m4) a = p3(A3[i]);
        f8:pack(e3m4) c = p3(B3[i]);
        Stdio.printf("%x %x:", A3[i], B3[i]);
        s3(a + c);
        s3(a - c);
        s3(a * c);
        s3(a / c);
        Stdio.printf("\n");
    }
}

u16 b4(f8:pack(e5m2, finite) x) { return (u16)*(u8*)&x; }
f8:pack(e5m2, finite) p4(u16 u) { u8 v = (u8)u; return *(f8:pack(e5m2, finite)*)&v; }

void s4(f8:pack(e5m2, finite) x)
{
    u16 b = b4(x);
    if ((b & $7F) == $7F)
        Stdio.printf(" nan");
    else
        Stdio.printf(" %x", b);
}

u16 A4[12] = {$7E, $7E, $3C, $01, $D0, $41, $BC, $60, $11, $F1, $4B, $8B};
u16 B4[12] = {$7E, $3C, $00, $40, $5F, $06, $E2, $E4, $3E, $DB, $6C, $83};

void ops4(void)
{
    for (u32 i = 0; i < 12; i++)
    {
        f8:pack(e5m2, finite) a = p4(A4[i]);
        f8:pack(e5m2, finite) c = p4(B4[i]);
        Stdio.printf("%x %x:", A4[i], B4[i]);
        s4(a + c);
        s4(a - c);
        s4(a * c);
        s4(a / c);
        Stdio.printf("\n");
    }
}

u16 b5(f8:pack(e2m5, none) x) { return (u16)*(u8*)&x; }
f8:pack(e2m5, none) p5(u16 u) { u8 v = (u8)u; return *(f8:pack(e2m5, none)*)&v; }

void s5(f8:pack(e2m5, none) x)
{
    u16 b = b5(x);
    if (false)
        Stdio.printf(" nan");
    else
        Stdio.printf(" %x", b);
}

u16 A5[12] = {$7F, $20, $00, $21, $01, $32, $26, $36, $23, $80, $8A, $D3};
u16 B5[12] = {$7F, $00, $00, $23, $A0, $A1, $51, $D3, $5D, $EE, $A3, $FE};

void ops5(void)
{
    for (u32 i = 0; i < 12; i++)
    {
        f8:pack(e2m5, none) a = p5(A5[i]);
        f8:pack(e2m5, none) c = p5(B5[i]);
        Stdio.printf("%x %x:", A5[i], B5[i]);
        s5(a + c);
        s5(a - c);
        s5(a * c);
        s5(a / c);
        Stdio.printf("\n");
    }
}

u16 h16(f16 x) { return *(u16*)&x; }

void misc(void)
{
    f8 x = 448.0;
    x++;
    f8 y = 0.5;
    y--;
    f8 z = 100;
    z *= 10;
    f8 w = 3;
    w /= 0.25;
    f8 n = p0($7F);
    Stdio.printf("step %x %x %x %x\n", b0(x), b0(y), b0(z), b0(w));
    Stdio.printf("neg %x %x %x\n", b0(-n), b0(-p0($00)), b1(-p1($7C)));
    f8 one = 1;
    f8 nz = -0.0;
    f8 pz = 0;
    Stdio.printf("cmp %d %d %d %d\n", (i32)(n < one), (i32)(nz == pz), (i32)(x > one), (i32)(one <= one));
    f8:pack(ue8m0) s = 0.5;
    f8:pack(ue8m0) t = 8;
    Stdio.printf("scale %x %x %d\n", b2(s * t), b2(t / s), (i32)(s < t));
    if (pz || nz)
        Stdio.printf("zero true\n");
    else
        Stdio.printf("zero false\n");
    if (s)
        Stdio.printf("scale true\n");
}

void mixed(void)
{
    f8 a = 448.0;
    f16 h = 448.0;
    f16 r = a + h;
    f32 quarter = 0.25;
    f32 f = a + quarter;
    f8:pack(e5m2) e = 57344.0;
    f16 r2 = e + h;
    f8:pack(e2m5, none) q = 7.875;
    f16 r3 = q * h;
    Stdio.printf("wide %x %x %x\n", h16(r), h16(r2), h16(r3));
    Stdio.printf("f32 %f\n", (f64)f);
    Stdio.printf("print %f %f %f\n", a, e, q);
}

i32 main(void)
{
    ops0();
    ops1();
    ops2();
    ops3();
    ops4();
    ops5();
    misc();
    mixed();
    return 0;
}
