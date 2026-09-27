// float_uint32_conv.xc — conversions a signed 32-bit instruction gets wrong.
//
// x86_64 and win64 converted every integer through cvtsi2* and cvtt*2si on a
// 32-bit register, which are SIGNED: a u32 of 3000000000 became the double
// -1294967296, a double of 3000000000 became the u32 0, and -2^31, which the
// "integer indefinite" also spells, became 0. Every value passes through a
// function so no pass folds it.
#import "Stdio.xc"

double idd(double v) { return v; }
float  idf(float v)  { return v; }
u32    idu(u32 v)    { return v; }

i32 main(void)
{
    Stdio.printf("u32_to_d %lu\n", (u32)(idd((double)idu(3000000000)) / 1000.0d));
    Stdio.printf("u32_to_f %lu\n", (u32)(idf((float)idu(4000000000)) / 1000.0));
    Stdio.printf("u32_max_to_d %s\n", (double)idu(4294967295) == 4294967295.0d ? "exact" : "wrong");
    Stdio.printf("d_to_u32 %lu\n", (u32)idd(3000000000.0d));
    Stdio.printf("f_to_u32 %lu\n", (u32)idf(4000000000.0));
    Stdio.printf("d_to_u32_max %lu\n", (u32)idd(4294967295.0d));
    Stdio.printf("d_to_i32_min %ld\n", (i32)idd(-2147483648.0d));
    Stdio.printf("f_to_i32_min %ld\n", (i32)idf(-2147483648.0));
    Stdio.printf("d_to_u16 %u\n", (u16)idd(60000.5d));
    Stdio.printf("d_to_i16 %d\n", (i16)idd(-30000.5d));
    Stdio.printf("f_to_u8 %u\n", (u32)(u8)idf(200.0));
    Stdio.printf("f_to_i8 %d\n", (i16)(i8)idf(-100.0));
    return 0;
}
