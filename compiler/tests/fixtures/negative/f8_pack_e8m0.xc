// e8m0 with a sign bit is nine bits; the exponent-only scale is unsigned,
// ue8m0.
// xtc: error "f8 has no pack 'e8m0': a signed pack has 1 + X + Y = 8 bits, e2m5 to e6m1 (e4m3 the default, e5m2), and the unsigned scale is ue8m0"
#import "Stdio.xc"

i32 main(void)
{
    f8:pack(e8m0) s = 1.0;
    Stdio.printf("%f\n", s);
    return 0;
}
