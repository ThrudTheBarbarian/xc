// float_to_int64.xc — a double or a float converted to i64 and u64.
//
// arm9 converted through the VFP's 32-bit form only, so the high word was
// left stale: `(i64)-3.0` printed 4294967293. Every value passes through a
// function so no pass folds it. int64_to_float.xc is the other direction.
#import "Stdio.xc"

double idd(double v) { return v; }
float  idf(float v)  { return v; }
i64    idi(i64 v)    { return v; }
u64    idu(u64 v)    { return v; }

void showI(string tag, i64 v) { Stdio.printf("cv_%s %s\n", tag, String.withI64(v).cString()); }
void showU(string tag, u64 v) { Stdio.printf("cv_%s %s\n", tag, String.withU64(v).cString()); }
// A float prints through its conversion back to an integer, which is exact
// for every value below: they are all integers the type holds.
void showD(string tag, double v) { Stdio.printf("cv_%s %s\n", tag, String.withI64((i64)v).cString()); }
void showUD(string tag, double v) { Stdio.printf("cv_%s %s\n", tag, String.withU64((u64)v).cString()); }

i32 main(void)
{
    // double / float to i64 and u64
    showI("d2i_neg3", (i64)idd(-3.0d));
    showI("d2i_neg3_5", (i64)idd(-3.5d));
    showI("d2i_5e9", (i64)idd(5000000000.75d));
    showI("d2i_neg5e9", (i64)idd(-5000000000.75d));
    showI("d2i_small", (i64)idd(0.5d));
    showI("d2i_2p62", (i64)idd(4611686018427387904.0d));
    showI("d2i_neg2p63", (i64)idd(-9223372036854775808.0d));
    showI("f2i_neg7", (i64)idf(-7.5));
    showI("f2i_2p40", (i64)idf(1099511627776.0));
    showU("d2u_12e9", (u64)idd(12345678900.5d));
    showU("d2u_2p63", (u64)idd(9223372036854775808.0d));
    showU("d2u_big", (u64)idd(18000000000000000000.0d));
    showU("d2u_small", (u64)idd(0.75d));
    showU("f2u_3", (u64)idf(3.0));
    showU("f2u_2p50", (u64)idf(1125899906842624.0));

    return 0;
}
