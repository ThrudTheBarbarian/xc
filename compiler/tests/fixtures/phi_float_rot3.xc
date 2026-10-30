// phi_float_rot3 — three floats rotated in a loop: a residual phi-copy cycle of
// three FP members. The arm64 back ends staged the third in d18, a home
// register, and wrote one rotated value over it (2026-10-30: printed 3 2 3).
#import "Stdio.xc"
i32 main(i32 argc, u8** argv)
{
    float a = 1.0;
    float b = 2.0;
    float c = 3.0;
    for (i32 i = 0; i < argc + 3; i++) {
        float t = a;
        a = b;
        b = c;
        c = t;
    }
    Stdio.printf("%d %d %d\n", (i32)a, (i32)b, (i32)c);
    return 0;
}
