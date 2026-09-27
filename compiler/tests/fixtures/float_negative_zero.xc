// float_negative_zero.xc — negating +0.0 gives -0.0, for float and double.
//
// Negation flips the sign bit. x86_64 and win64 computed `0 - x` instead,
// which is +0.0 for x = +0.0, so the literal `-0.0d` and `-x` of a zero both
// came out positive. The sign shows through division: 1 / -0.0 is -infinity.
//
//xtc-na: xt6502 — the 5-byte float format has no negative zero

#import "Stdio.xc"

double gd = 0.0d;
float gf = (float)0.0;
double gpos = 2.5d;

u32 negD(double x) { return (1.0d / x < 0.0d) ? (u32)1 : (u32)0; }
u32 negF(float x) { return ((float)1.0 / x < (float)0.0) ? (u32)1 : (u32)0; }

double flipD(double x) { return -x; }
float flipF(float x) { return -x; }

void main(void)
{
    double a = -0.0d;
    float b = -(float)0.0;
    Stdio.printf("literal  d=%d f=%d\n", (i32)negD(a), (i32)negF(b));
    Stdio.printf("variable d=%d f=%d\n", (i32)negD(-gd), (i32)negF(-gf));
    Stdio.printf("call     d=%d f=%d\n", (i32)negD(flipD(gd)), (i32)negF(flipF(gf)));
    Stdio.printf("twice    d=%d f=%d\n", (i32)negD(flipD(flipD(gd))), (i32)negF(flipF(flipF(gf))));
    Stdio.printf("nonzero  %d %d\n", (i32)(flipD(gpos) * 10.0d), (i32)(flipF((float)gpos) * (float)10.0));
}
