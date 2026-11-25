// overload_smallest_widening.xc — a call whose arguments widen to more than
// one overload goes to the one that needs the smaller widening (#643): a
// `(u32, u16)` call picks `(u32, u32)` over `(u64, u64)`, as C++ ranks
// conversions. A call that converts equally well to two overloads, or better
// to each on a different argument, is still ambiguous
// (tests/fixtures/negative/overload_crossed_widening.xc). A literal still
// picks the narrowest parameter it fits, as it always has.
#import "Stdio.xc"

class Chk
{
    static void eq(u32 a, u32 b) { Stdio.printf("eq u32\n"); }
    static void eq(u64 a, u64 b) { Stdio.printf("eq u64\n"); }
}
void pair(u32 a, u32 b) { Stdio.printf("pair u32 u32\n"); }
void pair(u64 a, u64 b) { Stdio.printf("pair u64 u64\n"); }
void pair(u16 a, u32 b) { Stdio.printf("pair u16 u32\n"); }
void lit(u16 v) { Stdio.printf("lit u16\n"); }
void lit(u32 v) { Stdio.printf("lit u32\n"); }
void sgn(i32 v) { Stdio.printf("sgn i32\n"); }
void sgn(i64 v) { Stdio.printf("sgn i64\n"); }

i32 main(void)
{
    u32 x = (u32)7;
    u16 h = (u16)3;
    u8 b = (u8)1;
    i16 s = (i16)-2;
    Chk.eq(x, h);          // eq u32
    Chk.eq(x, x);          // eq u32 (exact)
    pair(h, b);            // pair u16 u32: u16 exact, u8 -> u32
    pair(x, h);            // pair u32 u32
    lit(5);                // lit u16
    sgn(s);                // sgn i32
    return 0;
}
