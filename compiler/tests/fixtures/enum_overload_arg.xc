// An enum constant used as an argument to an OVERLOADED callee: the constant
// resolves as u8 and used to score no-match against the enum-typed parameter
// — while the identical argument sailed through a non-overloaded call. Found
// by Data.withStringEncoded during the 0.4 String work; the rank now mirrors
// the enum→int direction that always existed.
#import "Stdio.xc"
enum Mode = {M_OFF = 0, M_SLOW = 3, M_FAST = 7};
class Box {
    static u32 pick(u32 v) { return v; }
    static u32 pick(u32 v, Mode m) { return v + (u32)10 + (u32)m; }
    static u32 only(Mode m) { return (u32)100 + (u32)m; }
}
void main(void)
{
    Stdio.printf("%lu %lu %lu %lu\n",
                 Box.pick((u32)5), Box.pick((u32)5, M_FAST),
                 Box.only(M_SLOW), Box.pick((u32)2, (Mode)1));
}
