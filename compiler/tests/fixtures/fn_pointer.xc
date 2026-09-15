// fn_pointer.xc — stage 1 of function-pointer support.
//
// Covers:
//   T1  declare signature via typedef, take address, call once
//   T2  reassign the pointer between calls
//   T3  pass a pointer as a function argument (callback)
//   T4  pointer with multi-byte param + return
//
// Runtime dispatch goes through the _xtc_ijsr trampoline
// (support/generic/asm/ijsr.asm): caller stages target in $BE/$BF,
// JSRs the helper, helper does JMP ($00BE). Banked targets (xt/xe)
// promote address-taken functions to `:main` placement so the
// trampoline can reach them without a bank-switch step.

#import "Stdio.xc"

typedef u8 op_t(u8);
typedef u16 binop_t(u16, u16);

u8 addOne(u8 x) { return x + (u8)1; }
u8 dbl(u8 x)    { return x + x; }
u8 negate(u8 x) { return (u8)0 - x; }

u16 addW(u16 a, u16 b)  { return a + b; }
u16 mulW(u16 a, u16 b)  { return a * b; }

// T3: take a fn-pointer as a formal parameter — classic callback shape.
u8 applyU8(op_t* fn, u8 x) { return fn(x); }

void main(void) {
    // T1: declare, &-of, single call.
    op_t* fp = &addOne;
    u8 r1 = fp((u8)5);
    if (r1 == 6) { Stdio.printf("T1 PASS\n"); }
    else         { Stdio.printf("T1 FAIL r=%d\n", r1); }

    // T2: reassign the pointer.
    fp = &dbl;
    u8 r2 = fp((u8)7);
    fp = &negate;
    u8 r3 = fp((u8)10);    // 0 - 10 wraps to $F6 in u8
    if (r2 == 14 && r3 == $F6) { Stdio.printf("T2 PASS\n"); }
    else { Stdio.printf("T2 FAIL r2=%d r3=%x\n", r2, (u16)r3); }

    // T3: callback via function-pointer parameter.
    u8 r4 = applyU8(&addOne, (u8)100);
    u8 r5 = applyU8(&dbl,    (u8)50);
    if (r4 == 101 && r5 == 100) { Stdio.printf("T3 PASS\n"); }
    else { Stdio.printf("T3 FAIL r4=%d r5=%d\n", r4, r5); }

    // T4: u16 in, u16 out.
    binop_t* op = &addW;
    u16 s = op((u16)1000, (u16)2345);
    op = &mulW;
    u16 m = op((u16)123, (u16)45);
    if (s == 3345 && m == 5535) { Stdio.printf("T4 PASS\n"); }
    else { Stdio.printf("T4 FAIL s=%u m=%u\n", s, m); }
}
