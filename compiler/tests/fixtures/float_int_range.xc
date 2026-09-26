// float_int_range.xc — bug 264. Conversions between floating point and
// integers give the same answer on every target, at every width:
//   * float/double to an integer keeps the integral part, and a value that
//     does not fit a destination narrower than 64 bits gives 0;
//   * a u64 destination reaches past 2^63, and a negative value gives 0;
//   * an i64/u64 source keeps all 64 bits, including a u64 with its top bit
//     set, which a signed conversion would read as negative.
// xt6502 did all of these through a 32-bit integer and got each one wrong.
// Values are read from globals so the conversions happen at run time.

#import "Stdio.xc"

double gd[13];
float  gf[3];
i64    gi[2];
u64    gu[3];

// The output stays inside one xt6502 screen (under 24 lines of 40 columns).
void show(u8* tag, u64 v) { Stdio.printf("%s %lx:%lx\n", tag, (u32)(v >> (u64)32), (u32)v); }

void bits(u8* tag, double d)
{
    double t[1];
    t[0] = d;
    u64* p = (u64*)(pointer)(&t[0]);
    show(tag, p[0]);
}

void fbits(u8* tag, float f)
{
    float t[1];
    t[0] = f;
    u32* p = (u32*)(pointer)(&t[0]);
    Stdio.printf("%s %lx\n", tag, p[0]);
}

// float/double -> narrow integer: in range converts, out of range is 0
void toNarrow(void)
{
    show("u8 300.5", (u64)(u8)gd[0]);
    show("i8 200.5", (u64)(i64)(i8)gd[1]);
    show("i8 -100.5", (u64)(i64)(i8)gd[2]);
    show("u16 70000.5", (u64)(u16)gd[3]);
    show("i16 40000.5", (u64)(i64)(i16)gd[4]);
    show("u32 -1.5", (u64)(u32)gd[6]);
    show("u32 4e9", (u64)(u32)gd[7]);
    show("i32 -3e9", (u64)(i64)(i32)gd[8]);
    show("f i32 3e9", (u64)(i64)(i32)gf[0]);
    show("f u32 3e9", (u64)(u32)gf[0]);
}

// float/double -> 64-bit integer
void toWide(void)
{
    show("u64 -1.5", (u64)gd[6]);
    show("u64 1e19", (u64)gd[10]);
    show("i64 -5e9", (u64)(i64)gd[11]);
    show("u64 5e9", (u64)gd[12]);
    show("f i64 5e9", (u64)(i64)gf[1]);
    show("f u64 1e19", (u64)gf[2]);
}

// 64-bit integer -> float/double
void fromWide(void)
{
    bits("d i64", (double)gi[0]);
    bits("d -i64", (double)gi[1]);
    bits("d u64 2^63", (double)gu[0]);
    bits("d u64 2^63+4097", (double)gu[1]);
    bits("d u64 max", (double)gu[2]);
    fbits("f i64", (float)gi[0]);
    fbits("f u64 2^63", (float)gu[0]);
}

i32 main(void)
{
    gd[0] = 300.5d;   gd[1] = 200.5d;   gd[2] = -100.5d;  gd[3] = 70000.5d;
    gd[4] = 40000.5d; gd[5] = -30000.5d; gd[6] = -1.5d;   gd[7] = 4000000000.0d;
    gd[8] = -3000000000.0d; gd[9] = -2000000000.0d;
    gd[10] = 10000000000000000000.0d; gd[11] = -5000000000.0d; gd[12] = 5000000000.0d;
    gf[0] = 3000000000.0; gf[1] = 5000000000.0; gf[2] = 10000000000000000000.0;
    gi[0] = 12345678900; gi[1] = -12345678900;
    gu[0] = (u64)1 << (u64)63;
    gu[1] = ((u64)1 << (u64)63) + (u64)4097;
    gu[2] = (u64)0 - (u64)1;
    toNarrow();
    toWide();
    fromWide();
    return (i32)0;
}
