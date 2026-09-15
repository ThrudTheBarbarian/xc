// funcptr.xc — take the address of a function and call THROUGH the
// pointer (and through a function-pointer parameter), proving dispatch
// works and the computed result flows back.
#import "Stdio.xc"

typedef u8 op_t(u8);

u8 addSix(u8 x) { return x + (u8)6; }
u8 dbl(u8 x)    { return x + x; }

// callback: invoke the supplied function pointer
u8 apply(op_t* fn, u8 x) { return fn(x); }

void main(void)
{
    op_t* fp = &addSix;
    u8 a = fp((u8)90);          // 90 + 6 = 96
    fp = &dbl;
    u8 b = fp((u8)45);          // 45 + 45 = 90
    u8 c = apply(&addSix, (u8)3); // callback: 3 + 6 = 9
    Stdio.printf("a=%d b=%d c=%d\n", (u16)a, (u16)b, (u16)c);
}
