//xtc-flags: target=xt6502
// placement_main_xt6502.xc — `:main` keeps a function out of the code banks.
//
// Bug 267: on xt every function but main and the :irq/:vbi handlers goes in a
// code bank, and `:main` is documented to keep one in main RAM (functions.md,
// Placement). The annotation never reached the back end: a free function's
// symbol always said `banked: false` and carried no `main`, and the placement
// consulted only :irq/:vbi, so `i32 hot(i32 v) :main` still landed in a bank.
//
// The back end publishes every function's code bank as `__dbank_<name>` (0 is
// main RAM), which the asm block below reads.
//
// Test surface:
//   T1  a `:main` free function is in bank 0
//   T2  an unannotated free function is in a code bank
//   T3  a `:banked` free function is in a code bank
//   T4  the three, and a `:main` method, run and return the right values

#import "Stdio.xc"

u8 bankHot;
u8 bankPlain;
u8 bankCold;

i32 hot(i32 v) :main
{
    i32 s = v;
    for (i32 i = 0; i < 3; i = i + 1) {
        s = s + i;
        Stdio.printf(".");
    }
    return s;
}

i32 plain(i32 v)
{
    i32 s = v;
    for (i32 i = 0; i < 3; i = i + 1) {
        s = s + i * 2;
        Stdio.printf(".");
    }
    return s;
}

i32 cold(i32 v) :banked
{
    i32 s = v;
    for (i32 i = 0; i < 3; i = i + 1) {
        s = s + i * 3;
        Stdio.printf(".");
    }
    return s;
}

class Counter
{
    i32 n;
    i32 step(i32 by) :main
    {
        for (i32 i = 0; i < 2; i = i + 1) {
            n = n + by;
            Stdio.printf(".");
        }
        return n;
    }
}

void main(void)
{
    asm {
        LDA #__dbank_hot
        STA bankHot
        LDA #__dbank_plain
        STA bankPlain
        LDA #__dbank_cold
        STA bankCold
    }
    Stdio.printf("T1 :main free function in bank %u\n", bankHot);
    Stdio.printf("T2 unannotated free function banked %u\n", bankPlain != (u8)0 ? 1 : 0);
    Stdio.printf("T3 :banked free function banked %u\n", bankCold != (u8)0 ? 1 : 0);
    Counter* c = new Counter();
    i32 r = hot(10) + plain(20) + cold(30) + c.step(5);
    Stdio.printf("\nT4 %d\n", r);
}
