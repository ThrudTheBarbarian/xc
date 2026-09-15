// Regression for signed narrow → wider widening at runtime.
//
// Before the fix, `i16 widen(i8 x) { return x; }` called as
// `b = widen(-7)` came back as $??F9 — the low byte was right
// but the high byte was whatever stale value A/X happened to
// leave in emitReturn's register path. emitReturn called
// emitExprToA for the return expression without widening to
// the function's declared return width, so narrow signed
// results shipped with an unwidened X register. The fix routes
// the return value through emitWideStoreExtensionForRHS so the
// upper bytes (and for i32, the _u32HiReg pair) get sign-
// extended via the existing CMP #$80 / BCC / LDX #$FF chain.

#import "Stdio.xc"

i16 widen(i8 x) { return x; }
i32 widen32(i8 x) { return x; }
i16 addSigned(i8 a, i8 b) { return a + b; }

void main(void)
{
    i8 a = -5;
    i16 b;
    i32 c;

    // Direct i8 → i16 assignment.
    b = a;
    if (b == -5) { Stdio.printf("T1 PASS\n"); } else { Stdio.printf("T1 FAIL b=%d\n", b); }

    // Positive i8 → i16.
    a = 100;
    b = a;
    if (b == 100) { Stdio.printf("T2 PASS\n"); } else { Stdio.printf("T2 FAIL b=%d\n", b); }

    // Negative literal through a function returning wider signed.
    b = widen(-7);
    if (b == -7) { Stdio.printf("T3 PASS\n"); } else { Stdio.printf("T3 FAIL b=%d\n", b); }

    // i8 variable through a function returning wider signed.
    i8 d = -20;
    b = widen(d);
    if (b == -20) { Stdio.printf("T4 PASS\n"); } else { Stdio.printf("T4 FAIL b=%d\n", b); }

    // i8 → i32 (tests width-4 sign extension path through u32HiReg).
    c = widen32(-3);
    if (c == -3) { Stdio.printf("T5 PASS\n"); } else { Stdio.printf("T5 FAIL c=%ld\n", c); }

    // i8 + i8 returning i16 (both operands need to widen).
    b = addSigned(-10, -20);
    if (b == -30) { Stdio.printf("T6 PASS\n"); } else { Stdio.printf("T6 FAIL b=%d\n", b); }

    // Positive + negative.
    b = addSigned(100, -30);
    if (b == 70) { Stdio.printf("T7 PASS\n"); } else { Stdio.printf("T7 FAIL b=%d\n", b); }

    // i8 → i32 direct assignment (no call).
    i8 e = -10;
    c = e;
    if (c == -10) { Stdio.printf("T8 PASS\n"); } else { Stdio.printf("T8 FAIL c=%ld\n", c); }
}
