//xtc-flags: m68k-soft-float — the m68k leg builds this without -mhard-float
// math_softfloat.xc — every Math transcendental, float and double.
//
// On m68k, Math.sqrt/sin/cos/tan/atan/ln/exp/pow call `_xm_*` helpers. The
// back end used to define them only under -mhard-float, as 68881
// instructions, so a plain `-A m68k` or `-A 68030` build of any program using
// them failed to assemble with `undefined symbol '_xm_ln'`. Without the FPU
// they are line-A math HLE stubs, like the soft-float arithmetic. The
// directive above makes the corpus m68k leg take that path; the other
// back ends compare the same values.

#import "Stdio.xc"
#import "Math.xc"

u32 testCount;
u32 failCount;

void checkd(double got, double want)
{
    testCount = testCount + 1;
    double diff = got - want;
    if (diff < 0.0d) { diff = 0.0d - diff; }
    double w = want;
    if (w < 0.0d) { w = 0.0d - w; }
    if (w > 1.0d) { diff = diff / w; }
    if (diff > 0.000000001d) {
        Stdio.printf("D%u FAIL\n", testCount);
        failCount = failCount + 1;
    }
}

void checkf(float got, float want)
{
    testCount = testCount + 1;
    float diff = got - want;
    if (diff < 0.0) { diff = 0.0 - diff; }
    float w = want;
    if (w < 0.0) { w = 0.0 - w; }
    if (w > 1.0) { diff = diff / w; }
    if (diff > 0.000002) {
        Stdio.printf("F%u FAIL\n", testCount);
        failCount = failCount + 1;
    }
}

void main(void)
{
    testCount = 0;
    failCount = 0;

    double x = 0.75d;
    checkd(Math.sqrt(x), 0.8660254037844386d);                  // 1
    checkd(Math.sin(x), 0.6816387600233341d);                   // 2
    checkd(Math.cos(x), 0.7316888688738209d);                   // 3
    checkd(Math.tan(x), 0.9315964599440725d);                   // 4
    checkd(Math.atan(x), 0.6435011087932844d);                  // 5
    checkd(Math.ln(x), -0.2876820724517809d);                   // 6
    checkd(Math.exp(x), 2.117000016612675d);                    // 7
    checkd(Math.pow(x, 2.5d), 0.48713928962874d);               // 8
    checkd(Math.pow(x, 3), 0.421875d);                          // 9
    double e = Math.E();
    double ln2 = Math.LN2();
    checkd(Math.ln(e), 1.0d);                                   // 10
    checkd(Math.exp(ln2), 2.0d);                                // 11
    checkd(Math.pow(2.0d, 10.0d), 1024.0d);                     // 12

    float f = 0.75;
    checkf(Math.sqrt(f), 0.8660254);                            // 13
    checkf(Math.sin(f), 0.68163876);                            // 14
    checkf(Math.cos(f), 0.73168887);                            // 15
    checkf(Math.tan(f), 0.93159646);                            // 16
    checkf(Math.atan(f), 0.64350111);                           // 17
    checkf(Math.ln(f), -0.28768207);                            // 18
    checkf(Math.exp(f), 2.1170001);                             // 19
    checkf(Math.pow(f, 2.5), 0.48713929);                       // 20
    checkf(Math.pow(f, 3), 0.421875);                           // 21

    Stdio.printf("DONE %u\n", testCount);
    Stdio.printf("FAILED %u\n", failCount);
}
