// register_named_functions.xc — functions and globals named after registers.
//
// x86_64 and win64 renamed a data symbol that spells a register (`flags`,
// `si`) but not a function: `call si` assembled as an indirect call through
// %rsi and the program jumped into whatever the register held. The names
// below cover the registers of every back end: x86 (si, di, ax, sp, r8, xmm0,
// flags), arm64 (x0, w1, lr, fp, xzr), arm9 (r0, pc, ip, sl) and m68k (d0,
// a0, usp, sr). A function is called directly, called through a pointer and
// used as a callback.
#import "Stdio.xc"

i64 si(i64 v)   { return v + 1; }
i32 di(i32 v)   { return v * 2; }
i32 ax(void)    { return 3; }
i32 sp(i32 v)   { return v - 1; }
i32 r8(i32 v)   { return v + 8; }
i32 xmm0(void)  { return 10; }
i32 flags(void) { return 11; }
i32 x0(i32 v)   { return v + 100; }
i32 w1(void)    { return 12; }
i32 lr(void)    { return 13; }
i32 fp(void)    { return 14; }
i32 xzr(void)   { return 15; }
i32 r0(i32 v)   { return v + 16; }
i32 pc(void)    { return 17; }
i32 ip(void)    { return 18; }
i32 sl(void)    { return 19; }
i32 d0(void)    { return 20; }
i32 a0(void)    { return 21; }
i32 usp(void)   { return 22; }
i32 sr(void)    { return 23; }

i32 rbx = 5;
i32 eax = 6;

typedef i32 unary_t(i32 v);
i32 apply(unary_t* f, i32 v) { return f(v); }

i32 main(void)
{
    Stdio.printf("si %s\n", String.withI64(si(41)).cString());
    Stdio.printf("x86 %ld %ld %ld %ld %ld %ld\n", di(4), ax(), sp(9), r8(1), xmm0(), flags());
    Stdio.printf("arm64 %ld %ld %ld %ld %ld\n", x0(1), w1(), lr(), fp(), xzr());
    Stdio.printf("arm9 %ld %ld %ld %ld\n", r0(1), pc(), ip(), sl());
    Stdio.printf("m68k %ld %ld %ld %ld\n", d0(), a0(), usp(), sr());
    Stdio.printf("ptr %ld %ld %ld\n", apply(&di, 21), apply(&r0, 2), apply(&x0, 3));
    Stdio.printf("data %ld %ld\n", rbx, eax);
    return 0;
}
