// static_frame.xc — verifies the static-frame codegen path emits
// correct frame save/restore for eligible functions while the
// xtc-stack fallback continues to work for ineligible (recursive /
// address-taken) functions.
//
// Each test exercises a different fallback gate:
//   T1  direct non-recursive call chain → eligible
//   T2  direct recursion                → xtc-stack fallback
//   T3  address-taken function          → xtc-stack fallback on the taken fn
//
// Pass criteria: every function returns the correct value, so the
// frame save/restore (whether static-slot or xtc-stack) preserved
// the caller's ZP state across the call.

#import "Stdio.xc"

// ── T1: eligible — non-recursive DAG.
u8 plainAdd(u8 a, u8 b)
{
    return a + b;
}
u8 plainDouble(u8 x)
{
    return plainAdd(x, x);
}

// ── T2: ineligible — direct recursion. Must work via xtc-stack.
u16 factorial(u8 n)
{
    if (n <= 1) { return (u16)1; }
    return (u16)n * factorial(n - 1);
}

// ── T3: ineligible — address taken. The plain call still works
// through xtc-stack since addrTaken itself is flagged.
u8 addrTaken(u8 x)
{
    return x + $10;
}

void main(void)
{
    u8 a = plainDouble((u8)7);
    if (a == 14) { Stdio.printf("T1 PASS\n"); }
    else         { Stdio.printf("T1 FAIL a=%d\n", a); }

    u16 f = factorial((u8)5);
    if (f == 120) { Stdio.printf("T2 PASS\n"); }
    else          { Stdio.printf("T2 FAIL f=%u\n", f); }

    u8* fp = &addrTaken;
    u8 t = addrTaken((u8)5);
    if (t == $15 && fp != (u8*)0) { Stdio.printf("T3 PASS\n"); }
    else                          { Stdio.printf("T3 FAIL t=%x\n", (u16)t); }
}
