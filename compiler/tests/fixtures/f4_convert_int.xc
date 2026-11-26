// f4_convert_int.xc — f4 to every integer width and back. To an integer:
// toward zero, saturating (a negative value is 0 in an unsigned type), for
// all 16 patterns. From an integer: rounded to nearest even once, saturating
// to ±6, the largest and smallest of each width included. Expected values
// from the exact-rational model.
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

void toInt(void)
{
    Stdio.printf("to int\n");
    for (u16 b = 0; b < 16; b++)
        {
        f4 x = f4of(b);
        Stdio.printf("%d %u %d %u", (i16)(i8)x, (u16)(u8)x, (i16)x, (u16)x);
        Stdio.printf(" %d %u", (i16)(i32)x, (u16)(u32)x);
        Stdio.printf(" %d %u\n", (i16)(i64)x, (u16)(u64)x);
        }
}

void from_i8(void)
{
    Stdio.printf("i8");
    Stdio.printf(" %x", b4((f4)(i8)0));
    Stdio.printf(" %x", b4((f4)(i8)1));
    Stdio.printf(" %x", b4((f4)(i8)3));
    Stdio.printf(" %x", b4((f4)(i8)5));
    Stdio.printf(" %x", b4((f4)(i8)7));
    Stdio.printf(" %x", b4((f4)(i8)-1));
    Stdio.printf(" %x", b4((f4)(i8)-3));
    Stdio.printf(" %x", b4((f4)(i8)-5));
    Stdio.printf(" %x", b4((f4)(i8)-7));
    Stdio.printf(" %x", b4((f4)(i8)127));
    Stdio.printf(" %x", b4((f4)(i8)$80));
    Stdio.printf("\n");
}

void from_u8(void)
{
    Stdio.printf("u8");
    Stdio.printf(" %x", b4((f4)(u8)0));
    Stdio.printf(" %x", b4((f4)(u8)1));
    Stdio.printf(" %x", b4((f4)(u8)2));
    Stdio.printf(" %x", b4((f4)(u8)5));
    Stdio.printf(" %x", b4((f4)(u8)6));
    Stdio.printf(" %x", b4((f4)(u8)7));
    Stdio.printf(" %x", b4((f4)(u8)255));
    Stdio.printf("\n");
}

void from_i16(void)
{
    Stdio.printf("i16");
    Stdio.printf(" %x", b4((f4)(i16)4));
    Stdio.printf(" %x", b4((f4)(i16)-6));
    Stdio.printf(" %x", b4((f4)(i16)9));
    Stdio.printf(" %x", b4((f4)(i16)-9));
    Stdio.printf(" %x", b4((f4)(i16)32767));
    Stdio.printf(" %x", b4((f4)(i16)$8000));
    Stdio.printf("\n");
}

void from_u16(void)
{
    Stdio.printf("u16");
    Stdio.printf(" %x", b4((f4)(u16)3));
    Stdio.printf(" %x", b4((f4)(u16)11));
    Stdio.printf(" %x", b4((f4)(u16)65535));
    Stdio.printf("\n");
}

void from_i32(void)
{
    Stdio.printf("i32");
    Stdio.printf(" %x", b4((f4)(i32)0));
    Stdio.printf(" %x", b4((f4)(i32)1));
    Stdio.printf(" %x", b4((f4)(i32)5));
    Stdio.printf(" %x", b4((f4)(i32)-5));
    Stdio.printf(" %x", b4((f4)(i32)7));
    Stdio.printf(" %x", b4((f4)(i32)-7));
    Stdio.printf(" %x", b4((f4)(i32)100));
    Stdio.printf(" %x", b4((f4)(i32)-100));
    Stdio.printf(" %x", b4((f4)(i32)2147483647));
    Stdio.printf(" %x", b4((f4)(i32)$80000000));
    Stdio.printf("\n");
}

void from_u32(void)
{
    Stdio.printf("u32");
    Stdio.printf(" %x", b4((f4)(u32)0));
    Stdio.printf(" %x", b4((f4)(u32)6));
    Stdio.printf(" %x", b4((f4)(u32)7));
    Stdio.printf(" %x", b4((f4)(u32)4294967295));
    Stdio.printf("\n");
}

void from_i64(void)
{
    Stdio.printf("i64");
    Stdio.printf(" %x", b4((f4)(i64)5));
    Stdio.printf(" %x", b4((f4)(i64)-5));
    Stdio.printf(" %x", b4((f4)(i64)9223372036854775807));
    Stdio.printf(" %x", b4((f4)(i64)$8000000000000000));
    Stdio.printf("\n");
}

void from_u64(void)
{
    // Through a variable: a cast of the literal reads it as -1.
    u64 um = $FFFFFFFFFFFFFFFF;
    Stdio.printf("u64");
    Stdio.printf(" %x", b4((f4)(u64)5));
    Stdio.printf(" %x", b4((f4)um));
    Stdio.printf("\n");
}

i32 main(void)
{
    toInt();
    from_i8();
    from_u8();
    from_i16();
    from_u16();
    from_i32();
    from_u32();
    from_i64();
    from_u64();
    return 0;
}
