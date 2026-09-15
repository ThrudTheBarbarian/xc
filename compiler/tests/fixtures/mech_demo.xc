//xtc-flags: target=xt6502
// mech_demo.xc — a compiled xt6502 program showcasing the MECH math
// coprocessor. Every float/double operation and 32-bit integer divide below
// is lowered by the compiler to a MECH op-word program (map the math page,
// marshal operands into the slot file, ring the doorbell, read the result) and
// executed on the A9's FPU/libm — no 6502 software float or long division.
// See private:docs/Design/mech-offload-xt6502.md.

#import "Stdio.xc"
#import "Math.xc"

void main(void)
{
    Stdio.printf("=== MECH math coprocessor demo (xt6502) ===\n\n");

    // 1. 32-bit integer divide / modulo — MECH instead of ~2-3k-cycle software.
    u32 big = (u32)1000000; u32 d = (u32)7;
    Stdio.printf("[int]   1000000 / 7 = %ld   rem %ld\n", (i32)(big / d), (i32)(big % d));
    i32 sn = (i32)(0 - 98765); i32 sd = (i32)11;
    Stdio.printf("[int]   -98765 / 11 = %ld   rem %ld\n\n", sn / sd, sn % sd);

    // 2. IEEE single-precision (f32) arithmetic.
    float a = 3.5; float b = 1.25;
    Stdio.printf("[f32]   3.5 + 1.25 = %f\n", a + b);
    Stdio.printf("[f32]   3.5 * 1.25 = %f\n", a * b);
    Stdio.printf("[f32]   3.5 / 1.25 = %f\n\n", a / b);

    // 3. IEEE double-precision (f64) arithmetic.
    double x = 2.0d; double y = 3.0d;
    Stdio.printf("[f64]   2 / 3       = %.8lf\n", x / y);
    double pi = Math.PI();
    Stdio.printf("[f64]   pi          = %.8lf\n\n", pi);

    // 4. Transcendentals via MECH (sqrt = Newton in MECH float; exp = libm).
    Stdio.printf("[math]  sqrt(2)     = %.8lf\n", Math.sqrt(2.0d));
    Stdio.printf("[math]  sqrt(1000000) = %.4lf\n", Math.sqrt(1000000.0d));
    Stdio.printf("[math]  exp(1)      = %.8lf\n", Math.exp(1.0d));
    double s1 = Math.sin(1.0d); double c1 = Math.cos(1.0d);
    Stdio.printf("[math]  sin(1)      = %.8lf\n", s1);
    Stdio.printf("[math]  cos(1)      = %.8lf\n\n", c1);

    // 5. Conversions round-trip through MECH.
    double e = Math.exp(1.0d);
    i32 ei = (i32)(e * 1000000.0d);
    Stdio.printf("[conv]  (i32)(e * 1e6) = %ld\n", ei);
    float f = (float)ei;
    Stdio.printf("[conv]  back to f32 / 1e6 = %.6f\n\n", f / 1000000.0);

    // 6. A compound expression — the whole tree is a batch of MECH ops.
    float r = 4.0;
    float area = Math.PI() * r * r;
    Stdio.printf("[expr]  area of circle r=4 = %.5f\n", area);

    Stdio.printf("\n=== done ===\n");
}
