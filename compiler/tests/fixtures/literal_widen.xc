// Regression test for u8-fitting-literal → wider-param widening
// at the call site, across every call mechanism the compiler
// emits:
//
//   1. Plain function calls    : f(100)               → emitCallExpr
//   2. Self-method calls       : foo() inside class   → emitSelfMethodCall
//   3. Explicit class methods  : Klass.foo(100)       → emitMethodCallExpr
//
// Before the fix, `f(u16 x) { ... }` called as `f(100)` typed
// the literal `100` as u8 (since it fits) and the caller pushed
// 1 byte. The callee's prologue popped 2 bytes and read garbage
// for the high byte, producing values like 9416 instead of 100.
// Negative literals to signed wider params had the same issue
// with the additional twist that they needed sign-extension,
// not zero-extension — `f(-3)` to an i16 param widened to
// $00FD = 253 instead of $FFFD = -3.
//
// The fix walks each call site to look up the callee's
// declared param widths and widens narrow literal args at
// compile time (constant-fold via tryConstantEval) or zero-
// extends narrow variable args at run time (LDX #$00).
//
// Sweep with: python3 tests/run_literal_widen.py

#import "Stdio.xc"

u16 add3(u16 a, u16 b, u16 c) { return a + b + c; }
u16 doubleIt(u16 x) { return x + x; }
i16 sub(i16 a, i16 b) { return a - b; }
i16 add3i(i16 a, i16 b, i16 c) { return a + b + c; }

// Class methods (static) — Class.method() goes through a
// different code path than plain function calls.
class Helper
{
    u8 dummy;
    static u16 hAdd(u16 a, u16 b) { return a + b; }
    static i16 hSub(i16 a, i16 b) { return a - b; }
    static u16 hMix(u16 a, u16 b, u16 c) { return a + b + c; }
}

void main(void)
{
    u16 r;
    i16 sr;

    // u8-fitting positive literals into u16 params.
    r = add3(10, 20, 30);
    if (r == 60) { Stdio.printf("T1 PASS\n"); }
    else { Stdio.printf("T1 FAIL r=%u\n", r); }

    r = doubleIt(100);
    if (r == 200) { Stdio.printf("T2 PASS\n"); }
    else { Stdio.printf("T2 FAIL r=%u\n", r); }

    // Literal still fits in u8 but doubled overflows it.
    r = doubleIt(250);
    if (r == 500) { Stdio.printf("T3 PASS\n"); }
    else { Stdio.printf("T3 FAIL r=%u\n", r); }

    // Negative literal into i16 param.
    sr = sub(5, 100);
    if (sr == -95) { Stdio.printf("T4 PASS\n"); }
    else { Stdio.printf("T4 FAIL sr=%d\n", sr); }

    // Two negative literals — both need sign-extension.
    sr = sub(-3, -8);
    if (sr == 5) { Stdio.printf("T5 PASS\n"); }
    else { Stdio.printf("T5 FAIL sr=%d\n", sr); }

    // Negative literals into a 3-arg signed function.
    sr = add3i(-10, 20, -5);
    if (sr == 5) { Stdio.printf("T6 PASS\n"); }
    else { Stdio.printf("T6 FAIL sr=%d\n", sr); }

    // Zero literals — degenerate edge case.
    r = add3(0, 0, 0);
    if (r == 0) { Stdio.printf("T7 PASS\n"); }
    else { Stdio.printf("T7 FAIL r=%u\n", r); }

    // ── Class.method() literals (emitMethodCallExpr) ────────

    r = Helper.hAdd(10, 20);
    if (r == 30) { Stdio.printf("T8 PASS\n"); }
    else { Stdio.printf("T8 FAIL r=%u\n", r); }

    r = Helper.hAdd(100, 200);
    if (r == 300) { Stdio.printf("T9 PASS\n"); }
    else { Stdio.printf("T9 FAIL r=%u\n", r); }

    // The asymmetric negative test: previously `Helper.hSub(-3, 5)`
    // packed -3 as $00FD (253), so 253 - 5 = 248. The fix emits
    // $FFFD via const-fold so the callee sees the real -3.
    sr = Helper.hSub(-3, 5);
    if (sr == -8) { Stdio.printf("T10 PASS\n"); }
    else { Stdio.printf("T10 FAIL sr=%d\n", sr); }

    sr = Helper.hSub(5, -3);
    if (sr == 8) { Stdio.printf("T11 PASS\n"); }
    else { Stdio.printf("T11 FAIL sr=%d\n", sr); }

    // Three-arg class method with mixed-sized literals.
    r = Helper.hMix(50, 200, 100);
    if (r == 350) { Stdio.printf("T12 PASS\n"); }
    else { Stdio.printf("T12 FAIL r=%u\n", r); }
}
