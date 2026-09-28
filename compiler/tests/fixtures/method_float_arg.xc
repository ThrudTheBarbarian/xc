// method_float_arg.xc — a scalar argument crossed into a `double`
// parameter of a METHOD is a CONVERSION (SIToFp / UIToFp / FpExt), not
// an integer widen. The reference lowering used to pick SExt/ZExt/Trunc
// purely from the two widths, so `c.m(2.0)` passed the float's bit
// pattern and the callee read a denormal ~0.0; only the free-function
// call path was float-aware. The port was already correct, so this pins
// both.
//
// All comparisons are scaled to integers so no %f formatting is needed.

#import "Stdio.xc"
#import "Assert.xc"

class C
{
    i32 pad;
    double m(double d) { return d; }
    static double sm(double d) { return d; }
}

void main(void)
{
    Assert.reset();
    C* c = new C();

    double a = c.m(2.0);    // float literal  -> FpExt
    double b = c.m(2.0f);   // f suffix       -> FpExt
    float fl = 3.5;
    double d = c.m(fl);     // float local    -> FpExt
    i32 si = 4;
    double e = c.m(si);     // signed int     -> SIToFp
    u32 ui = 5;
    double f = c.m(ui);     // unsigned int   -> UIToFp
    double st = C.sm(7.0);  // static method

    Assert.isEqual((i32)(a * 1000.0), 2000);
    Assert.isEqual((i32)(b * 1000.0), 2000);
    Assert.isEqual((i32)(d * 1000.0), 3500);
    Assert.isEqual((i32)(e * 1000.0), 4000);
    Assert.isEqual((i32)(f * 1000.0), 5000);
    Assert.isEqual((i32)(st * 1000.0), 7000);

    Assert.summary();
    return;
}
