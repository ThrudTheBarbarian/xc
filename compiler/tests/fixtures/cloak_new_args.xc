// cloak_new_args.xc — regression for `new T(args)` when T's init is
// :cloaked.
//
// Bug: the codegen pushed init's args via PHA on the hw stack while
// the cloaked init reads them from the $B0..$BF register window. The
// pushed bytes sat orphaned across the cloaked-bracket's PLA chain,
// shifting every subsequent pop and corrupting the call's PORTB +
// bank-restore + caller's return address. Fix: detect cloaked init
// and write args left-to-right into the reg window (mirror of the
// cloaked method-call convention from emitCloakedRegArg).

#import "Stdio.xc"

class Box
{
    u8 a;
    u16 b;
    u8 c;

    void init(u8 ai, u16 bi, u8 ci) : cloaked
    {
        a = ai;
        b = bi;
        c = ci;
    }

    u8  getA(void) : cloaked { return a; }
    u16 getB(void) : cloaked { return b; }
    u8  getC(void) : cloaked { return c; }
}

void main(void)
{
    // Three instances exercise mixed widths (u8, u16, u8) and span
    // the boundary cases. After the bug fix, the cloaked init reads
    // each arg from the right $B0..$BF slot rather than picking up
    // shifted bytes from the orphan-PHA chain.
    Box* b1 = new Box(7, 1024, 9);
    Box* b2 = new Box(255, 65535, 128);
    Box* b3 = new Box(0, 0, 0);

    u16 fails = 0;
    if (b1.getA() != 7)     fails++;
    if (b1.getB() != 1024)  fails++;
    if (b1.getC() != 9)     fails++;
    if (b2.getA() != 255)   fails++;
    if (b2.getB() != 65535) fails++;
    if (b2.getC() != 128)   fails++;
    if (b3.getA() != 0)     fails++;
    if (b3.getB() != 0)     fails++;
    if (b3.getC() != 0)     fails++;

    if (fails == 0) Stdio.printf("DONE 9\n");
    else            Stdio.printf("FAIL %u\n", fails);
}
