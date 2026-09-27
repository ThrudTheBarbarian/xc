// int64_to_float_round.xc — i64 and u64 to float where the value has bits
// below the double's last place.
//
// The float must be the nearest to the INTEGER. Going through a double first
// rounds twice: 2^60 + 2^36 + 1 becomes the double 2^60 + 2^36, a tie, which
// then goes to the even 2^60 instead of up to 2^60 + 2^37. arm9's
// __floatdisf folds the dropped bits into a sticky bit to avoid that.
// xt6502 converts through a double and rounds twice, so this is not shared
// with it.
//xtc-flags: target=arm64
#import "Stdio.xc"

i64    idi(i64 v)    { return v; }
u64    idu(u64 v)    { return v; }

void showD(string tag, double v) { Stdio.printf("cv_%s %s\n", tag, String.withI64((i64)v).cString()); }
void showUD(string tag, double v) { Stdio.printf("cv_%s %s\n", tag, String.withU64((u64)v).cString()); }

i32 main(void)
{
    showD("i2f_sticky", (double)(float)idi(1152921573326323713)); // 2^60 + 2^36 + 1: past the tie
    showD("i2f_tie60", (double)(float)idi(1152921573326323712));  // 2^60 + 2^36: a tie, to even
    showUD("u2f_2p63p", (double)(float)idu(9223372586610589697)); // 2^63 + 2^39 + 1: past the tie, up
    return 0;
}
