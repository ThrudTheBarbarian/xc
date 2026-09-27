// float_nan_compare.xc — every floating comparison follows IEEE on a NaN.
//
// With an unordered operand (a NaN), ==, <, <=, > and >= are false and != is
// true. x86_64 and win64 read only ZF after ucomisd, which an unordered
// compare also sets, so NaN == NaN was true and NaN != NaN false. The m68k
// soft-float compare returns 1 for an unordered pair, which read as
// "greater". Covers float and double, branches, materialised bools and the
// conditional-expression (Select) form.
//
//xtc-na: xt6502 — the 5-byte float format has no NaN

#import "Stdio.xc"

double gz = 0.0d;
double gone = 1.0d;

// Branch forms, one function per operator so the compare feeds a CondBranch.
u32 beq(double a, double b) { if (a == b) return (u32)1; return (u32)0; }
u32 bne(double a, double b) { if (a != b) return (u32)1; return (u32)0; }
u32 blt(double a, double b) { if (a < b) return (u32)1; return (u32)0; }
u32 ble(double a, double b) { if (a <= b) return (u32)1; return (u32)0; }
u32 bgt(double a, double b) { if (a > b) return (u32)1; return (u32)0; }
u32 bge(double a, double b) { if (a >= b) return (u32)1; return (u32)0; }

u32 feq(float a, float b) { if (a == b) return (u32)1; return (u32)0; }
u32 fne(float a, float b) { if (a != b) return (u32)1; return (u32)0; }
u32 flt(float a, float b) { if (a < b) return (u32)1; return (u32)0; }
u32 fle(float a, float b) { if (a <= b) return (u32)1; return (u32)0; }
u32 fgt(float a, float b) { if (a > b) return (u32)1; return (u32)0; }
u32 fge(float a, float b) { if (a >= b) return (u32)1; return (u32)0; }

// Select form: a conditional expression the if-converter can turn into a Select.
u32 seq(double a, double b) { return a == b ? (u32)7 : (u32)3; }
u32 sne(double a, double b) { return a != b ? (u32)7 : (u32)3; }
u32 slt(double a, double b) { return a < b ? (u32)7 : (u32)3; }
u32 sge(double a, double b) { return a >= b ? (u32)7 : (u32)3; }

void show(char* what, double a, double b)
{
    // Materialised bools.
    bool m0 = a == b;
    bool m1 = a != b;
    bool m2 = a < b;
    bool m3 = a <= b;
    bool m4 = a > b;
    bool m5 = a >= b;
    Stdio.printf("%s d-bool %d%d%d%d%d%d\n", what, (i32)m0, (i32)m1, (i32)m2, (i32)m3, (i32)m4, (i32)m5);
    Stdio.printf("%s d-br   %d%d%d%d%d%d\n", what, (i32)beq(a, b), (i32)bne(a, b), (i32)blt(a, b),
                 (i32)ble(a, b), (i32)bgt(a, b), (i32)bge(a, b));
    float fa = (float)a;
    float fb = (float)b;
    bool n0 = fa == fb;
    bool n1 = fa != fb;
    bool n2 = fa < fb;
    bool n3 = fa <= fb;
    bool n4 = fa > fb;
    bool n5 = fa >= fb;
    Stdio.printf("%s f-bool %d%d%d%d%d%d\n", what, (i32)n0, (i32)n1, (i32)n2, (i32)n3, (i32)n4, (i32)n5);
    Stdio.printf("%s f-br   %d%d%d%d%d%d\n", what, (i32)feq(fa, fb), (i32)fne(fa, fb), (i32)flt(fa, fb),
                 (i32)fle(fa, fb), (i32)fgt(fa, fb), (i32)fge(fa, fb));
    Stdio.printf("%s sel    %d%d%d%d\n", what, (i32)seq(a, b), (i32)sne(a, b), (i32)slt(a, b), (i32)sge(a, b));
}

void main(void)
{
    double nan = gz / gz;
    show("nan,nan", nan, nan);
    show("nan,1  ", nan, gone);
    show("1,nan  ", gone, nan);
    show("1,1    ", gone, gone);
    show("0,1    ", gz, gone);
    show("1,0    ", gone, gz);
}
