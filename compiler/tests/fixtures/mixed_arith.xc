//xtc-flags: skip  — byte-compares retired 5/8-byte softfloat results (dead dp*/fp* routines / old byte layout); obsolete under IEEE via MECH (phase-671). Values covered by mech_demo + mech_float_ops.
// mixed_arith.xc — regression coverage for binary expressions
// that mix a float operand with an integer operand of varying
// width and signedness. Each test captures the 5 raw bytes of
// the result and compares against a hand-computed expected
// encoding. Float byte format is { flags, exp, m0, m1, m2 }
// with implicit-leading-1 normalised mantissa, sign in bit 0 of
// flags, and a $10 zero flag for true zero.
//
// Group H extends the matrix to mixed-double shapes: double/int
// of every width, double/float, float/double, and double
// compound-assign. Those tests capture 8 bytes against expected
// dp encodings; dpRecord() and the 8-byte e0..e7 / r0..r7
// scratch slots live alongside the float group's 5-byte ones.
//
// Coverage matrix:
//   Group A: float + <intvar>                 (T1..T6)
//   Group B: <intvar> + float                 (T7..T12)
//   Group C: float OP <u16/u8> for - * /      (T13..T15)
//   Group D: mixed sub-expressions            (T16..T17)
//   Group E: mixed comparisons                (T18..T20)
//   Group F: mixed call arguments             (T21..T22)
//   Group G: float OP= <intvar>               (T23..T26)
//   Group H: double/int/float mixed ops       (T33..)

// Split into per-group functions + tagged xt6502: the single
// main overflows the xt6502 unbanked code budget (entry can't be
// banked/split), and the $B0-mailbox staging is 6502 inline asm the
// arm64 reference backend can't run.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
#import "Stdio.xc"

u8 r0;
u8 r1;
u8 r2;
u8 r3;
u8 r4;

u8 e0;
u8 e1;
u8 e2;
u8 e3;
u8 e4;

// dp extras for Group H. r0..r4 / e0..e4 are reused as the top 5
// bytes of the 8-byte capture; the bottom 3 live in these.
u8 r5; u8 r6; u8 r7;
u8 e5; u8 e6; u8 e7;

u8 testCount;
u8 failCount;
u8 fails[32];

void record(void)
{
    testCount = testCount + 1;
    if (r0 != e0 || r1 != e1 || r2 != e2 || r3 != e3 || r4 != e4) {
        if (failCount < 32) { fails[failCount] = testCount; }
        failCount = failCount + 1;
    }
}

void dpRecord(void)
{
    testCount = testCount + 1;
    if (r0 != e0 || r1 != e1 || r2 != e2 || r3 != e3 ||
        r4 != e4 || r5 != e5 || r6 != e6 || r7 != e7) {
        if (failCount < 32) { fails[failCount] = testCount; }
        failCount = failCount + 1;
    }
}

float fadd(float a, float b) { return a + b; }
float fmul(float a, float b) { return a * b; }


void t_g1(void)
{
    // ── Group A: float + <intvar> for every int width ──────────
    // 6.0 + 3 = 9.0 = 1.125 * 2^3 → exp=3, m0=$20.
    { float f = 6.0; u8  x = 3;  float r = f + x;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$03; e2=$20; e3=$00; e4=$00; record(); }

    // 6.0 + (-2) = 4.0 = 1.0 * 2^2.
    { float f = 6.0; i8  x = -2; float r = f + x;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$02; e2=$00; e3=$00; e4=$00; record(); }

    { float f = 6.0; u16 x = 3;  float r = f + x;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$03; e2=$20; e3=$00; e4=$00; record(); }

    { float f = 6.0; i16 x = -2; float r = f + x;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$02; e2=$00; e3=$00; e4=$00; record(); }

    { float f = 6.0; u32 x = 3;  float r = f + x;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$03; e2=$20; e3=$00; e4=$00; record(); }

    { float f = 6.0; i32 x = -2; float r = f + x;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$02; e2=$00; e3=$00; e4=$00; record(); }

}

void t_g2(void)
{
    // ── Group B: <intvar> + float (operand order swapped) ──────
    { u8  x = 3;  float f = 6.0; float r = x + f;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$03; e2=$20; e3=$00; e4=$00; record(); }

    { i8  x = -2; float f = 6.0; float r = x + f;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$02; e2=$00; e3=$00; e4=$00; record(); }

    { u16 x = 3;  float f = 6.0; float r = x + f;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$03; e2=$20; e3=$00; e4=$00; record(); }

    { i16 x = -2; float f = 6.0; float r = x + f;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$02; e2=$00; e3=$00; e4=$00; record(); }

    { u32 x = 3;  float f = 6.0; float r = x + f;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$03; e2=$20; e3=$00; e4=$00; record(); }

    { i32 x = -2; float f = 6.0; float r = x + f;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$02; e2=$00; e3=$00; e4=$00; record(); }

}

void t_g3(void)
{
    // ── Group C: subtraction, multiplication, division ─────────
    // 5.0 - 1 = 4.0
    { float f = 5.0; u16 x = 1; float r = f - x;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$02; e2=$00; e3=$00; e4=$00; record(); }

    // 2.5 * 4 = 10.0 = 1.25 * 2^3.
    { float f = 2.5; u8  x = 4; float r = f * x;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$03; e2=$40; e3=$00; e4=$00; record(); }

    // 8.0 / 2 = 4.0
    { float f = 8.0; u16 x = 2; float r = f / x;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$02; e2=$00; e3=$00; e4=$00; record(); }

}

void t_g4(void)
{
    // ── Group D: mixed sub-expressions ─────────────────────────
    // 2.0 * (u16 3 + 1) = 2.0 * 4 = 8.0 = 1.0 * 2^3.
    // The (x + 1) sub-expression stays in u16, then widens to
    // float for the outer multiply.
    { float f = 2.0; u16 x = 3; float r = f * (x + 1);
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$03; e2=$00; e3=$00; e4=$00; record(); }

    // (u16 6 - 2) * 2.0 = 4 * 2.0 = 8.0
    { float f = 2.0; u16 x = 6; float r = (x - 2) * f;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$03; e2=$00; e3=$00; e4=$00; record(); }

}

void t_g5(void)
{
    // ── Group E: mixed comparisons (bool result) ───────────────
    // Capture the bool in r0 and zero r1..r4 / e1..e4.
    // 5.0 > i16 3 → true (1).
    { float f = 5.0; i16 x = 3; bool b = f > x;
      r0 = b; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 5.0 < i16 3 → false (0).
    { float f = 5.0; i16 x = 3; bool b = f < x;
      r0 = b; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 0; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // u32 100 == 100.0 → true (1).
    { u32 x = 100; float f = 100.0; bool b = x == f;
      r0 = b; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

}

void t_g6(void)
{
    // ── Group F: mixed call args (int widens to float param) ───
    // fadd(6.0, u16 3) = 9.0
    { float f = 6.0; u16 x = 3; float r = fadd(f, x);
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$03; e2=$20; e3=$00; e4=$00; record(); }

    // fmul(u8 2, 5.0) = 10.0
    { u8 x = 2; float f = 5.0; float r = fmul(x, f);
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$03; e2=$40; e3=$00; e4=$00; record(); }

}

void t_g7(void)
{
    // ── Group G: compound assign with int *variable* RHS ───────
    // (T134 in float_arith.xc covers literal RHS; this group
    // covers the variable-RHS path, which has to load the int
    // and convert to float at runtime rather than fold at
    // compile time.)
    // 4.0 + 7 = 11.0 = 1.375 * 2^3.
    { float r = 4.0; u8  k = 7; r += k;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$03; e2=$60; e3=$00; e4=$00; record(); }

    // 6.0 - 2 = 4.0
    { float r = 6.0; u16 k = 2; r -= k;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$02; e2=$00; e3=$00; e4=$00; record(); }

    // 2.5 * 4 = 10.0
    { float r = 2.5; u8  k = 4; r *= k;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$03; e2=$40; e3=$00; e4=$00; record(); }

    // 8.0 / 2 = 4.0
    { float r = 8.0; u16 k = 2; r /= k;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0=$00; e1=$02; e2=$00; e3=$00; e4=$00; record(); }

}

void t_g8(void)
{
    // ── Group H: bare assign of int variable to float (NO decl) ────
    // The local-var-decl form `float f = x;` already routes through
    // emitFloatExprToB0's int conversion branch, but the bare
    // assignment `f = x;` (with f and x already declared) used to
    // fall through to the generic narrow integer assign at the
    // bottom of emitAssignExpr — packing 1-2 bytes of x into f and
    // leaving the upper float bytes as garbage. Each test below
    // declares both vars first, then assigns.
    //
    // The reassignment chain `x = N1; f = x; ... x = N2; f = x;`
    // hit this same path repeatedly, which is how the bug originally
    // surfaced — each `f = x` after the first overwrote f with
    // garbage. Tests T27..T32 cover one width per call to widen the
    // matrix to all six int sizes.

    // u8 → float (200 = 1.5625 * 2^7 → exp 7, m0 $90).
    { float f; u8 x;
      x = 200; f = x;
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      e0=$00; e1=$07; e2=$90; e3=$00; e4=$00; record(); }

    // i8 → float (-7 = -1.75 * 2^2 → sign + exp 2 + m0 $C0).
    { float f; i8 x;
      x = -7; f = x;
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      e0=$01; e1=$02; e2=$C0; e3=$00; e4=$00; record(); }

    // u16 → float (1000 = 1.953125 * 2^9, frac = 0.953125 → mantissa $F4).
    { float f; u16 x;
      x = 1000; f = x;
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      e0=$00; e1=$09; e2=$F4; e3=$00; e4=$00; record(); }

    // i16 → float (-1000 = -(1.953125 * 2^9) → sign + $09,$F4,$00,$00).
    { float f; i16 x;
      x = -1000; f = x;
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      e0=$01; e1=$09; e2=$F4; e3=$00; e4=$00; record(); }

    // u32 → float, then a SECOND assignment to the same `f` from a
    // different value of the same `x`. This is the exact reassign-
    // ment chain pattern from the original bug report — without the
    // fix, the second `f = x` packs garbage into the upper float
    // bytes and the value comes out wrong.
    { float f; u32 x;
      x = 1000000; f = x;
      x = 100;     f = x;
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      // 100 = 1.5625 * 2^6 → exp 6, m0 $90.
      e0=$00; e1=$06; e2=$90; e3=$00; e4=$00; record(); }

    // i32 → float, also via the reassignment chain.
    { float f; i32 x;
      x = -1; f = x;
      x = -2; f = x;
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      // -2 = -(1.0 * 2^1) → sign + exp 1 + mantissa 0.
      e0=$01; e1=$01; e2=$00; e3=$00; e4=$00; record(); }

}

void t_g9(void)
{
    // ── Group H: double / int / float mixed ops ────────────────
    // Cases reuse the same small integer values from Group A so
    // the expected dp mantissas (widened from 24 to 48 bits) are
    // all zero in the lower bytes — any nonzero low byte is a
    // real bug.

    // T33: double + u8. 6.0d + 3 = 9.0d = 1.125 * 2^3.
    { double d = 6.0d; u8 x = 3; double r = d + x;
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0=$00; e1=$03; e2=$20; e3=$00; e4=$00; e5=$00; e6=$00; e7=$00; dpRecord(); }

    // T34: double + i16 (negative). 6.0d + (-2) = 4.0d.
    { double d = 6.0d; i16 x = -2; double r = d + x;
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0=$00; e1=$02; e2=$00; e3=$00; e4=$00; e5=$00; e6=$00; e7=$00; dpRecord(); }

    // T35: double + u32. Exercises u32ToDp on the RHS widen.
    { double d = 6.0d; u32 x = 3; double r = d + x;
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0=$00; e1=$03; e2=$20; e3=$00; e4=$00; e5=$00; e6=$00; e7=$00; dpRecord(); }

    // T36: u8 + double (RHS-double reversal). 3 + 6.0d = 9.0d.
    { double d = 6.0d; u8 x = 3; double r = x + d;
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0=$00; e1=$03; e2=$20; e3=$00; e4=$00; e5=$00; e6=$00; e7=$00; dpRecord(); }

    // T37: float + double → double. Float widens to double; low
    //      mantissa bytes of the float widen as zero and the dp
    //      add should preserve that.
    { float f = 6.0; double d = 3.0d; double r = f + d;
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0=$00; e1=$03; e2=$20; e3=$00; e4=$00; e5=$00; e6=$00; e7=$00; dpRecord(); }

    // T38: double * float → double. 6.0d * 2.0 = 12.0d = 1.5 * 2^3.
    { double d = 6.0d; float f = 2.0; double r = d * f;
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0=$00; e1=$03; e2=$80; e3=$00; e4=$00; e5=$00; e6=$00; e7=$00; dpRecord(); }

    // T39: double / int. 12.0d / 4 = 3.0d = 1.5 * 2^1.
    { double d = 12.0d; u8 x = 4; double r = d / x;
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0=$00; e1=$01; e2=$80; e3=$00; e4=$00; e5=$00; e6=$00; e7=$00; dpRecord(); }

    // T40: double += int compound. d starts at 6.0d, += 3 → 9.0d.
    { double d = 6.0d; u8 x = 3; d += x;
      asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
            LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
      e0=$00; e1=$03; e2=$20; e3=$00; e4=$00; e5=$00; e6=$00; e7=$00; dpRecord(); }

    // T41: mixed comparison. double > int, true branch should run.
    { double d = 10.0d; u8 x = 5; u8 got = 0;
      if (d > x) { got = 1; }
      e0 = 1; r0 = got;
      e1 = 0; r1 = 0; e2 = 0; r2 = 0; e3 = 0; r3 = 0; e4 = 0; r4 = 0;
      e5 = 0; r5 = 0; e6 = 0; r6 = 0; e7 = 0; r7 = 0;
      dpRecord(); }

}

void main(void)
{
    testCount = 0;
    failCount = 0;

    t_g1();
    t_g2();
    t_g3();
    t_g4();
    t_g5();
    t_g6();
    t_g7();
    t_g8();
    t_g9();

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 32) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}
