// float_const_fold — floats of constants fold in the IR (2026-10-30): an
// int-to-float conversion of a constant and float arithmetic of two constants
// become one constant, in the type's own precision. `(float)W` with W a u16
// literal stayed a UIToFp, and `1.5f / (float)W` a division on every item,
// which kept the escape vectoriser off mandel_deep's par body. The values must
// be the IEEE results the hardware gives, so the program prints the same
// before and after; the IR check is in tests/driver/float-const-fold.sh.
#import "Stdio.xc"
#define W 4096
i32 main(i32 argc, u8** argv)
{
    float step = 1.5f / (float)W;
    float third = 1.0f / 3.0f;
    double dthird = (double)1 / (double)3;
    float neg = (float)(i16)-7 * 0.5f;
    float big = (float)(u32)4294967295;
    float s = 0.0f;
    for (u32 i = 0; i < (u32)(argc + 3); i++)
        s = s + (float)i * step;
    Stdio.printf("%.9g %.9g %.17g %.9g %.9g %.9g\n", (double)step, (double)third, dthird, (double)neg, (double)big, (double)s);
    return 0;
}
