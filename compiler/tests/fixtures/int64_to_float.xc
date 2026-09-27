// int64_to_float.xc — an i64 or a u64 converted to a double or a float.
//
// arm9 converted the low word only: `(double)5000000000` was 705032704. Every
// value passes through a function so no pass folds it. The values include the
// rounding edges of an integer a double or float cannot hold exactly (round
// to nearest even); int64_to_float_round.xc has the float cases below a
// double's last place.
// float_to_int64.xc is the other direction.
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
    // i64 and u64 to double
    showD("i2d_5e9", (double)idi(5000000000));
    showD("i2d_neg5e9", (double)idi(-5000000000));
    showD("i2d_neg1", (double)idi(-1));
    showD("i2d_2p53p1", (double)idi(9007199254740993));     // a tie: to even, 2^53
    showD("i2d_2p53p3", (double)idi(9007199254740995));     // a tie: to even, up
    showD("i2d_min", (double)idi(-9223372036854775807 - 1));
    showUD("u2d_12e9", (double)idu(12345678900));
    showUD("u2d_2p63", (double)idu(9223372036854775808));
    showUD("u2d_max", (double)idu(18446744073709549568));   // exact in a double
    showUD("u2d_near", (double)idu(18446744073709550591));  // rounds down to the one above

    // i64 and u64 to float
    showD("i2f_5e9", (double)(float)idi(5000000000));
    showD("i2f_neg5e9", (double)(float)idi(-5000000000));
    showD("i2f_tie", (double)(float)idi(16777217));          // 2^24+1: to even, 2^24
    showD("i2f_tie_up", (double)(float)idi(16777219));       // 2^24+3: to even, up
    showUD("u2f_12e9", (double)(float)idu(12345678900));
    return 0;
}
