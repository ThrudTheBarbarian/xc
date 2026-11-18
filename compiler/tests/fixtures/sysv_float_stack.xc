// sysv_float_stack.xc — float and double arguments past xmm7 (#313). Under
// x86-64 SysV a float argument past the eight SSE registers goes on the stack,
// in the next outgoing slot in source order, interleaved with integers past
// r9. Plain calls with 9 to 12 doubles and 10 floats, integers and doubles
// that both overflow (interleaved), a parameter the callee never reads, a
// virtual method, a protocol method and a call through a function pointer all
// print what the arm64 build prints. Each argument is weighted so that a
// dropped or shifted one changes the result. The self-calls keep real calls
// at -O3.
#import "Stdio.xc"

typedef double nine_t(double a, double b, double c, double d, double e, double f, double g, double h, double k);

protocol Weigher
{
    double weigh(double a, double b, double c, double d, double e, double f, double g, double h, double k, double l);
}

class Base : Object <Weigher>
{
    double weigh(double a, double b, double c, double d, double e, double f, double g, double h, double k, double l)
    {
        return a + b * 2.0 + c * 3.0 + d * 4.0 + e * 5.0 + f * 6.0 + g * 7.0 + h * 8.0 + k * 9.0 + l * 10.0;
    }
    double mix(i64 n, double a, double b, double c, double d, double e, double f, double g, double h, double k, i64 m) { return 0.0; }
}

class Derived : Base
{
    double mix(i64 n, double a, double b, double c, double d, double e, double f, double g, double h, double k, i64 m)
    {
        return a + (double)n * 1000.0 + b * 2.0 + c * 3.0 + d * 4.0 + e * 5.0 + f * 6.0 + g * 7.0 + h * 8.0 + k * 9.0 + (double)m * 100.0;
    }
}

double nine(double a, double b, double c, double d, double e, double f, double g, double h, double k)
{
    if (k < 0.0)
        return nine(a, b, c, d, e, f, g, h, 0.0 - k);
    return a + b * 2.0 + c * 3.0 + d * 4.0 + e * 5.0 + f * 6.0 + g * 7.0 + h * 8.0 + k * 9.0;
}

double twelve(double a, double b, double c, double d, double e, double f, double g, double h, double k, double l, double m, double n)
{
    return a + b * 2.0 + c * 3.0 + d * 4.0 + e * 5.0 + f * 6.0 + g * 7.0 + h * 8.0 + k * 9.0 + l * 10.0 + m * 11.0 + n * 12.0;
}

float tenf(float a, float b, float c, float d, float e, float f, float g, float h, float k, float l)
{
    if (l < (float)0.0)
        return tenf(a, b, c, d, e, f, g, h, k, (float)0.0 - l);
    return a + b * (float)2.0 + c * (float)3.0 + d * (float)4.0 + e * (float)5.0 + f * (float)6.0 + g * (float)7.0 + h * (float)8.0 + k * (float)9.0 + l * (float)10.0;
}

// Floats and doubles mixed: the float past xmm7 still takes a whole 8-byte slot.
double mixedWidth(float a, double b, float c, double d, float e, double f, float g, double h, float k, double l)
{
    return b * 2.0 + (double)a + (double)c * 3.0 + d * 4.0 + (double)e * 5.0 + f * 6.0 + (double)g * 7.0 + h * 8.0 + (double)k * 9.0 + l * 10.0;
}

// Eight integers and ten doubles, interleaved: the stack takes n7, d9, n8 and
// d10, in that order.
double interleaved(i64 n1, double d1, i64 n2, double d2, i64 n3, double d3, i64 n4, double d4, i64 n5, double d5,
                   i64 n6, double d6, i64 n7, double d7, double d8, double d9, i64 n8, double d10)
{
    if (d10 < 0.0)
        return interleaved(n1, d1, n2, d2, n3, d3, n4, d4, n5, d5, n6, d6, n7, d7, d8, d9, n8, 0.0 - d10);
    double is = (double)(n1 + n2 * (i64)2 + n3 * (i64)3 + n4 * (i64)4 + n5 * (i64)5 + n6 * (i64)6 + n7 * (i64)7 + n8 * (i64)8);
    double ds = d1 + d2 * 2.0 + d3 * 3.0 + d4 * 4.0 + d5 * 5.0 + d6 * 6.0 + d7 * 7.0 + d8 * 8.0 + d9 * 9.0 + d10 * 10.0;
    return is * 1000.0 + ds;
}

// The ninth double is never read; the integer after it still comes from rdi's
// successor registers, not from a register the double took.
double unusedNinth(double a, double b, double c, double d, double e, double f, double g, double h, double skip, i64 n, double last)
{
    return a + b + c + d + e + f + g + h + (double)n * 100.0 + last * 1000.0;
}

i32 main(void)
{
    Stdio.printf("%f\n", nine(1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0));
    Stdio.printf("%f\n", nine(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, -9.0));
    Stdio.printf("%f\n", twelve(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0));
    Stdio.printf("%f\n", (double)tenf((float)1.0, (float)2.0, (float)3.0, (float)4.0, (float)5.0, (float)6.0, (float)7.0, (float)8.0, (float)9.0, (float)-10.0));
    Stdio.printf("%f\n", mixedWidth((float)1.0, 2.0, (float)3.0, 4.0, (float)5.0, 6.0, (float)7.0, 8.0, (float)9.0, 10.0));
    Stdio.printf("%f\n", interleaved((i64)1, 1.5, (i64)2, 2.5, (i64)3, 3.5, (i64)4, 4.5, (i64)5, 5.5,
                                     (i64)6, 6.5, (i64)7, 7.5, 8.5, 9.5, (i64)8, -10.5));
    Stdio.printf("%f\n", unusedNinth(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 99.0, (i64)7, 3.0));
    Base* b = new Derived();
    Stdio.printf("%f\n", b.mix((i64)4, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, (i64)5));
    Weigher* w = b;
    Stdio.printf("%f\n", w.weigh(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0));
    nine_t@ p = &nine;
    Stdio.printf("%f\n", p(2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0));
    Stdio.printf("%f %f %f %f %f %f %f %f %f %f\n", 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0);
    return 0;
}
