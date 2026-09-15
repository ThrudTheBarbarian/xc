// mech_int_div.xc — 32-bit integer mul/div/mod. On xt6502 these lower to the
// MECH math coprocessor (see private:docs/Design/mech-offload-xt6502.md); on every
// other backend they use native/software arithmetic. All backends must agree,
// so this doubles as a differential check that MECH matches the reference.

#import "Stdio.xc"

void main(void)
{
    u32 a = (u32)1000000; u32 b = (u32)7;
    i32 c = (i32)(0 - 1000000); i32 d = (i32)7;
    i32 e = (i32)(0 - 1000000); i32 f = (i32)(0 - 7);

    Stdio.printf("u mul=%ld div=%ld mod=%ld\n", (i32)(a * b), (i32)(a / b), (i32)(a % b));
    Stdio.printf("s div=%ld mod=%ld\n", (i32)(c / d), (i32)(c % d));
    Stdio.printf("ss div=%ld mod=%ld\n", (i32)(e / f), (i32)(e % f));
}
