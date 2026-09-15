//xtc-flags: target=xt6502  — exercises the xt6502 MECH float path; cross-backend %f formatting differs (m68k truncates where xt6502/arm64 round), so not a shared oracle
// mech_float_ops.xc — value-based regression for the xt6502 MECH float path.
// Every op runs on the MECH coprocessor; checks VALUES via printf (not the
// retired byte layout), replacing the byte-compare coverage the retired
// softfloat fixtures (double_*, mixed_arith, …) gave. xt6502-only: the values
// are IEEE-deterministic, but %f formatting isn't identical across backends.

#import "Stdio.xc"
#import "Math.xc"

void main(void)
{
    // f32 arithmetic
    float a = 3.5; float b = 1.25;
    Stdio.printf("f32 %f %f %f %f\n", a + b, a - b, a * b, a / b);

    // f64 arithmetic
    double x = 2.0d; double y = 3.0d;
    Stdio.printf("f64 %.6lf %.6lf %.6lf %.6lf\n", x + y, x - y, x * y, x / y);

    // signed narrow-int -> float (regression for the sign-extend fix, phase-684)
    i8  n8  = (i8)(0 - 3);
    i16 n16 = (i16)(0 - 300);
    i32 n32 = (i32)(0 - 70000);
    Stdio.printf("sitofp %.1f %.1f %.1f\n", (float)n8, (float)n16, (float)n32);

    // float <-> double and float -> int
    float f = 1.5; double d = (double)f;
    Stdio.printf("cvt %.6lf %ld\n", d, (i32)(a * 4.0));

    // comparisons
    Stdio.printf("cmp %ld %ld %ld\n",
        (i32)(a > b), (i32)(x < y), (i32)(d == 1.5d));

    // transcendentals
    Stdio.printf("math %.6lf %.6lf %.6lf %.6lf\n",
        Math.sqrt(2.0d), Math.sin(1.0d), Math.cos(1.0d), Math.exp(1.0d));
}
