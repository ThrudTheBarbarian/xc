// math_rand_float_range.xc — Math.rand() for float and double: range,
// distribution and seeding.
//
// Every target returns a value in [0.5, 1.0). The generators differ (libc
// random() on the hosted targets, a 16-bit xorshift on xt6502), so the
// checks compare statistics rather than values: every draw in range, the
// mean near 0.75, each quarter of the range drawn about equally often,
// and the same seed giving the same sequence.
//
// On xt6502 both overloads packed their result as the retired 5- and
// 8-byte softfloat layouts, which read as IEEE gave values near 0.

#import "Stdio.xc"
#import "Math.xc"

u16 testCount;
u16 failCount;

void check(bool ok)
{
    testCount = testCount + 1;
    if (!ok) {
        Stdio.printf("T%u FAIL\n", testCount);
        failCount = failCount + 1;
    }
}

// 2000 draws: mean 0.75, standard error 0.0032; each quarter expects
// 500 with a standard deviation of about 19.
void statsFloat(u16 seed)
{
    Math.setSeed(seed);
    u16 n = 2000;
    u16 bad = 0;
    u16 q0 = 0;
    u16 q1 = 0;
    u16 q2 = 0;
    u16 q3 = 0;
    float sum = 0.0;
    float lo = 1.0;
    float hi = 0.0;
    u16 i;
    for (i = 0; i < n; i = i + 1) {
        float v = Math.rand();
        if (v < 0.5 || v >= 1.0) { bad = bad + 1; }
        if (v < lo) { lo = v; }
        if (v > hi) { hi = v; }
        sum = sum + v;
        if (v < 0.625) { q0 = q0 + 1; }
        else if (v < 0.75) { q1 = q1 + 1; }
        else if (v < 0.875) { q2 = q2 + 1; }
        else { q3 = q3 + 1; }
    }
    float mean = sum / 2000.0;
    check(bad == 0);
    check(mean > 0.73 && mean < 0.77);
    check(lo < 0.51 && hi > 0.99);
    check(q0 > 400 && q0 < 600);
    check(q1 > 400 && q1 < 600);
    check(q2 > 400 && q2 < 600);
    check(q3 > 400 && q3 < 600);
}

void statsDouble(u16 seed)
{
    Math.setSeed(seed);
    u16 n = 2000;
    u16 bad = 0;
    u16 q0 = 0;
    u16 q1 = 0;
    u16 q2 = 0;
    u16 q3 = 0;
    double sum = 0.0d;
    double lo = 1.0d;
    double hi = 0.0d;
    u16 i;
    for (i = 0; i < n; i = i + 1) {
        double v = Math.rand();
        if (v < 0.5d || v >= 1.0d) { bad = bad + 1; }
        if (v < lo) { lo = v; }
        if (v > hi) { hi = v; }
        sum = sum + v;
        if (v < 0.625d) { q0 = q0 + 1; }
        else if (v < 0.75d) { q1 = q1 + 1; }
        else if (v < 0.875d) { q2 = q2 + 1; }
        else { q3 = q3 + 1; }
    }
    double mean = sum / 2000.0d;
    check(bad == 0);
    check(mean > 0.73d && mean < 0.77d);
    check(lo < 0.51d && hi > 0.99d);
    check(q0 > 400 && q0 < 600);
    check(q1 > 400 && q1 < 600);
    check(q2 > 400 && q2 < 600);
    check(q3 > 400 && q3 < 600);
}

void main(void)
{
    testCount = 0;
    failCount = 0;

    statsFloat(1234);                                   // T1-T7
    statsFloat(7);                                      // T8-T14
    statsDouble(1234);                                  // T15-T21
    statsDouble(7);                                     // T22-T28

    // Same seed, same sequence; successive draws differ.
    Math.setSeed(1234);
    float fa = Math.rand();
    float fb = Math.rand();
    Math.setSeed(1234);
    float fa2 = Math.rand();
    float fb2 = Math.rand();
    check(fa == fa2 && fb == fb2);                      // T29
    check(fa != fb);                                    // T30

    Math.setSeed(1234);
    double da = Math.rand();
    double db = Math.rand();
    Math.setSeed(1234);
    double da2 = Math.rand();
    double db2 = Math.rand();
    check(da == da2 && db == db2);                      // T31
    check(da != db);                                    // T32

    // A different seed gives a different sequence.
    Math.setSeed(4321);
    float fc = Math.rand();
    Math.setSeed(4321);
    double dc = Math.rand();
    check(fc != fa);                                    // T33
    check(dc != da);                                    // T34

    // The double draw carries more than float precision: some draw in a
    // short run is not exactly representable as a float.
    Math.setSeed(99);
    u16 wide = 0;
    u16 k;
    for (k = 0; k < 16; k = k + 1) {
        double d = Math.rand();
        float f = (float)d;
        if ((double)f != d) { wide = wide + 1; }
    }
    check(wide > 0);                                    // T35

    // Float and double draws from the same seed agree to float precision.
    Math.setSeed(555);
    float ff = Math.rand();
    Math.setSeed(555);
    double dd = Math.rand();
    double gap = dd - (double)ff;
    if (gap < 0.0d) { gap = 0.0d - gap; }
    check(gap < 0.000001d);                             // T36

    Stdio.printf("DONE %u\n", testCount);
    Stdio.printf("FAILED %u\n", failCount);
}
