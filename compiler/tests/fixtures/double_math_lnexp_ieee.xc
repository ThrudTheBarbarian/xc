// double_math_lnexp_ieee.xc — Math.ln / Math.exp / Math.pow on IEEE doubles.
//
// double_math_lnexp.xc checks the same identities, but it reads each result
// through a 6502 `asm { LDA d ... }` block and compares the bytes against the
// retired 8-byte softfloat layout, so it only ever meant anything on the 6502.
// Built for m68k it compiled cleanly with the asm dropped and printed FAIL
// lines, which read as a 68881 fault. This version compares values against a
// tolerance and runs on every back end (the m68k corpus leg builds with
// -mhard-float, so it covers the 68881 flogn / fetox path).

#import "Stdio.xc"
#import "Math.xc"

u32 testCount;
u32 failCount;

void check(double got, double want)
{
    testCount = testCount + 1;
    double diff = got - want;
    if (diff < 0.0d) { diff = 0.0d - diff; }
    if (diff > 0.000000001d) {
        Stdio.printf("T%u FAIL\n", testCount);
        failCount = failCount + 1;
    }
}

void main(void)
{
    testCount = 0;
    failCount = 0;
    double e = Math.E();
    double ln2 = Math.LN2();

    check(Math.ln(1.0d), 0.0d);                        // T1
    check(Math.ln(2.0d), 0.693147180559945d);          // T2
    check(Math.ln(e), 1.0d);                           // T3
    check(Math.exp(0.0d), 1.0d);                       // T4
    check(Math.exp(1.0d), 2.718281828459045d);         // T5
    check(Math.exp(ln2), 2.0d);                        // T6
    check(Math.pow(1.0d, 2.0d), 1.0d);                 // T7
    check(Math.pow(2.0d, 10.0d), 1024.0d);             // T8
    check(Math.ln(10.0d), 2.302585092994046d);         // T9
    check(Math.exp(-1.0d), 0.367879441171442d);        // T10

    Stdio.printf("DONE %u\n", testCount);
    Stdio.printf("FAILED %u\n", failCount);
}
