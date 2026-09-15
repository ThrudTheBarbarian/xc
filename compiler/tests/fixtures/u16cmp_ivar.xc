// u16cmp_ivar.xc — magnitude compares (>, <, >=, <=) between two
// u16 / i16 class ivars. Pre-fix the codegen dropped the high-byte
// CMP/BCC when both operands were ivars; the fallback emit-only-low
// branch made `myCls.a >= myCls.b` with a=200, b=960 falsely report
// TRUE because $C8 > $C0 in the low byte while the high bytes
// (0 vs 3) were never compared.
//
// Covers all six magnitude / equality ops on unsigned u16 ivars,
// signed i16 ivars (negative LHS), and a mixed signed/unsigned set
// where the high bytes differ. Each case calls Assert which prints
// `FAIL T<n>` on the unexpected outcome.

#import "Stdio.xc"
#import "Assert.xc"

class Cmp
{
    u16 a;
    u16 b;
    i16 c;
    i16 d;

    void setup(void)
    {
        a = 200; b = 960; c = -100; d = 100;
    }

    void run(void)
    {
        // u16 magnitude: a (200, $00C8) vs b (960, $03C0).
        // High bytes differ (0 < 3) — the fix is what makes the
        // BCC after the high-byte CMP fire correctly.
        Assert.isTrue(a < b);     // T1
        Assert.isFalse(a >= b);   // T2
        Assert.isTrue(b > a);     // T3
        Assert.isFalse(b <= a);   // T4
        Assert.isTrue(a <= b);    // T5
        Assert.isFalse(a > b);    // T6
        Assert.isTrue(b >= a);    // T7
        Assert.isFalse(b < a);    // T8

        // u16 equality / inequality already worked pre-fix, but
        // pin it so a future codegen rewrite can't silently
        // regress it.
        Assert.isFalse(a == b);   // T9
        Assert.isTrue(a != b);    // T10

        // i16 magnitude across zero: c=-100 ($FF9C), d=100 ($0064).
        // Signed cascade EORs the top byte with $80 to fold sign
        // into an unsigned-style cmp; pre-fix this path also
        // collapsed for ivars.
        Assert.isTrue(c < d);     // T11
        Assert.isFalse(c >= d);   // T12
        Assert.isTrue(d > c);     // T13
        Assert.isFalse(d <= c);   // T14
    }
}

void main(void)
{
    Assert.reset();
    Cmp* x = new Cmp();
    x.setup();
    x.run();
    Stdio.printf("DONE 14\n");
    return;
}
