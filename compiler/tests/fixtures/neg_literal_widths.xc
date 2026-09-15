// A negated literal takes the narrowest SIGNED type that fits the NEGATED
// value — not the width of the literal it negates. `-181` does not fit i8, so
// typing it there wraps the negate to 75 and the sign-extend preserves the
// wrong number (private:docs/bugs/111, uxkit 034-C: every round cap came out off its
// circle because the arc table is written -181, -237, …).
#import "Stdio.xc"

i32 main(void)
{
    i32 a = -5;            // fits i8
    i32 b = -181;          // needs i16
    i32 c = -237;          // needs i16
    i32 d = -40000;        // needs i32
    i32 e = -128;          // the i8 boundary
    i32 f = -129;          // one past it
    Stdio.printf("%ld %ld %ld %ld %ld %ld\n", a, b, c, d, e, f);
    return (i32)0;
}
