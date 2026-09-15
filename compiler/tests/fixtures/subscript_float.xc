// subscript_float.xc — coverage for float/double array subscripts.
//
// Stores distinctive float/double values into a heap array via
// subscript, reads them back via subscript (const and dynamic
// index) and prints them. The printed values are the oracle.
//
// (Was a red guard for the Ptr(Void) element-stride bug fixed in
// phase-334; double rows use %lf — the width-suffixed specifier for
// a double, see the note below — and now pass on both backends.)

#import "Stdio.xc"

void main(void)
{
    float* fp = new float[5];
    fp[0] = 1.5;
    fp[1] = 2.5;
    fp[2] = 3.5;
    fp[3] = 4.5;
    fp[4] = 5.5;

    Stdio.printf("F0=%f\n", fp[0]);
    Stdio.printf("F1=%f\n", fp[1]);
    Stdio.printf("F2=%f\n", fp[2]);
    Stdio.printf("F3=%f\n", fp[3]);
    Stdio.printf("F4=%f\n", fp[4]);

    u8 idx = 2;
    Stdio.printf("FDYN=%f\n", fp[idx]);

    fp[idx] = 99.5;
    Stdio.printf("FW2=%f\n", fp[2]);

    u8 j = 3;
    fp[j] = 7.25;
    Stdio.printf("FW3=%f\n", fp[3]);

    delete fp;

    double* dp = new double[2];
    dp[0] = 1.25d;
    dp[1] = 2.5d;
    // %lf is the width-suffixed specifier for a `double` (matching the
    // %d/%ld convention); %f is for the 5-byte `float`. (xt6502's %f is
    // lenient and also accepts a double; arm64's is strict, reading
    // float width — so a double MUST use %lf to be portable.)
    Stdio.printf("D0=%lf\n", dp[0]);
    Stdio.printf("D1=%lf\n", dp[1]);

    u8 k = 0;
    dp[k] = 42.0d;
    Stdio.printf("DW0=%lf\n", dp[0]);

    delete dp;
    return;
}
