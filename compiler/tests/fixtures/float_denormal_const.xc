// float_denormal_const.xc — single-precision denormal constants.
//
// A float literal below 2^-126 is a denormal, and keeps its value: 1e-40 is
// 9.9999461e-41, the smallest denormal is 1.40129846e-45, and the largest one
// sits just below the smallest normal. Each back end narrows a double constant
// to float bits itself, and that step flushed every denormal to zero. Far
// below the smallest denormal the value is zero.

#import "Stdio.xc"

i32 main(void)
{
    float a = 1e-40;
    float b = 1.4e-45;
    float c = 1.1754942e-38;
    float z = 1e-50;
    float n = -1e-40;
    Stdio.printf("%.9g %.9g %.9g %.9g %.9g\n", (double)a, (double)b, (double)c, (double)z, (double)n);
    return 0;
}
