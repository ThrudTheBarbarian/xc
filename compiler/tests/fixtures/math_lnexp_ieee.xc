// math_lnexp_ieee.xc — Math.ln / Math.exp / Math.pow for float and double
// across the exponent range.
//
// ln splits its argument into mantissa and exponent. On xt6502 that split
// read the retired 5- and 8-byte softfloat layouts (the exponent from byte 1),
// which under IEEE gave ln(e) = 61.30 for double and garbage for float. The
// cases here reach large, small and subnormal exponents, where a wrong split
// is off by far more than the tolerance.

#import "Stdio.xc"
#import "Math.xc"

u32 testCount;
u32 failCount;

// Relative error above 1, absolute below.
void checkd(double got, double want, double tol)
{
    testCount = testCount + 1;
    double diff = got - want;
    if (diff < 0.0d) { diff = 0.0d - diff; }
    double w = want;
    if (w < 0.0d) { w = 0.0d - w; }
    if (w > 1.0d) { diff = diff / w; }
    if (diff > tol) {
        Stdio.printf("D%u FAIL\n", testCount);
        failCount = failCount + 1;
    }
}

void checkf(float got, float want, float tol)
{
    testCount = testCount + 1;
    float diff = got - want;
    if (diff < 0.0) { diff = 0.0 - diff; }
    float w = want;
    if (w < 0.0) { w = 0.0 - w; }
    if (w > 1.0) { diff = diff / w; }
    if (diff > tol) {
        Stdio.printf("F%u FAIL\n", testCount);
        failCount = failCount + 1;
    }
}

void main(void)
{
    testCount = 0;
    failCount = 0;

    double t = 0.000000000001d;
    checkd(Math.ln(0.5d), -0.693147180559945d, t);                // 1
    checkd(Math.ln(1.5d), 0.405465108108164d, t);                 // 2
    checkd(Math.ln(1.9999d), 0.693097179309934d, t);              // 3
    checkd(Math.ln(100.0d), 4.605170185988091d, t);               // 4
    checkd(Math.ln(0.001d), -6.907755278982137d, t);              // 5
    checkd(Math.ln(1.0E300d), 690.7755278982137d, t);             // 6
    checkd(Math.ln(1.0E-300d), -690.7755278982137d, t);           // 7
    double sub = 1.0E-300d;
    sub = sub / 10000000000.0d;                                   // subnormal
    checkd(Math.ln(sub), -713.8013788281542d, t);                 // 8
    checkd(Math.exp(10.0d), 22026.465794806718d, t);              // 9
    checkd(Math.exp(-10.0d), 0.0000453999297624848515d, t);       // 10
    checkd(Math.exp(2.5d), 12.182493960703473d, t);               // 11
    checkd(Math.pow(2.0d, 0.5d), 1.4142135623730951d, t);         // 12
    checkd(Math.pow(10.0d, 3.0d), 1000.0d, t);                    // 13
    checkd(Math.pow(3.0d, -2.0d), 0.111111111111111d, t);         // 14
    checkd(Math.pow(1.5d, 7.25d), 18.908698112379714d, t);        // 15

    float tf = 0.000002;
    checkf(Math.ln(1.0), 0.0, tf);                                // 16
    checkf(Math.ln(2.0), 0.6931472, tf);                          // 17
    checkf(Math.ln(2.7182817), 1.0, tf);                          // 18
    checkf(Math.ln(10.0), 2.3025851, tf);                         // 19
    checkf(Math.ln(0.5), -0.6931472, tf);                         // 20
    checkf(Math.ln(1000.0), 6.9077554, tf);                       // 21
    checkf(Math.ln(0.001), -6.9077554, tf);                       // 22
    checkf(Math.ln(1.0E30), 69.077553, tf);                       // 23
    checkf(Math.exp(0.0), 1.0, tf);                               // 24
    checkf(Math.exp(1.0), 2.7182817, tf);                         // 25
    checkf(Math.exp(-1.0), 0.36787944, tf);                       // 26
    checkf(Math.exp(5.0), 148.41316, tf);                         // 27
    checkf(Math.pow(2.0, 10.0), 1024.0, tf);                      // 28
    checkf(Math.pow(2.0, 0.5), 1.4142135, tf);                    // 29
    checkf(Math.pow(9.0, 0.5), 3.0, tf);                          // 30

    Stdio.printf("DONE %u\n", testCount);
    Stdio.printf("FAILED %u\n", failCount);
}
