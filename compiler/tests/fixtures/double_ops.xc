//xtc-flags: skip  — byte-compares retired 5/8-byte softfloat results (dead dp*/fp* routines / old byte layout); obsolete under IEEE via MECH (phase-671). Values covered by mech_demo + mech_float_ops.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// double_ops.xc — regression for Tier 1 compiler-level surfaces:
//   - double comparison operators (==, !=, <, >, <=, >=)
//   - (float)d and (double)f casts
//   - float + double mixed arithmetic (auto-widen to double)
//
// These paths are NOT exercised by double_add/mul/div/cvt (which
// JSR the runtime directly from asm blocks). Each block here uses
// ordinary xtc syntax so the test lights up codegen bugs in the
// operator lowering.
//
// Split into multiple functions so the banker can place each one
// in a separate code bank — main() alone was too large for the
// unbanked region ($D800-$FFF9 ~8.5 KB).
//
// Byte-encoding reference:
//    1.5f  = {$00, $00, $80, $00, $00}
//   -3.0f  = {$01, $01, $80, $00, $00}
//    1.5d  = {$00, $00, $80, $00, $00, $00, $00, $00}
//    3.0d  = {$00, $01, $80, $00, $00, $00, $00, $00}
//   -3.0d  = {$01, $01, $80, $00, $00, $00, $00, $00}

#import "Stdio.xc"

u8 r0; u8 r1; u8 r2; u8 r3; u8 r4; u8 r5; u8 r6; u8 r7;
u8 e0; u8 e1; u8 e2; u8 e3; u8 e4; u8 e5; u8 e6; u8 e7;

u8 testCount;
u8 failCount;
u8 fails[16];

void record(void)
{
    testCount = testCount + 1;
    if (r0 != e0 || r1 != e1 || r2 != e2 || r3 != e3 ||
        r4 != e4 || r5 != e5 || r6 != e6 || r7 != e7) {
        if (failCount < 16) { fails[failCount] = testCount; }
        failCount = failCount + 1;
    }
}

// Zero all eight r/e slots. Comparison tests only write r0/e0; the
// others stay zero so the 8-byte record() check stays meaningful.
void clear(void)
{
    r0 = 0; r1 = 0; r2 = 0; r3 = 0; r4 = 0; r5 = 0; r6 = 0; r7 = 0;
    e0 = 0; e1 = 0; e2 = 0; e3 = 0; e4 = 0; e5 = 0; e6 = 0; e7 = 0;
}

// ── Comparison operators (T1-T15) ────────────────────────────────
void testComparisons(void)
{
    // T1: 1.5 < 2.0 → TRUE
    { clear(); double a = 1.5d; double b = 2.0d;
      if (a < b) { r0 = 1; } e0 = 1; record(); }

    // T2: 2.0 < 1.5 → FALSE
    { clear(); double a = 2.0d; double b = 1.5d;
      if (a < b) { r0 = 1; } e0 = 0; record(); }

    // T3: 1.5 < 1.5 → FALSE (equal)
    { clear(); double a = 1.5d; double b = 1.5d;
      if (a < b) { r0 = 1; } e0 = 0; record(); }

    // T4: 2.0 > 1.5 → TRUE
    { clear(); double a = 2.0d; double b = 1.5d;
      if (a > b) { r0 = 1; } e0 = 1; record(); }

    // T5: 1.5 > 2.0 → FALSE
    { clear(); double a = 1.5d; double b = 2.0d;
      if (a > b) { r0 = 1; } e0 = 0; record(); }

    // T6: 1.5 == 1.5 → TRUE
    { clear(); double a = 1.5d; double b = 1.5d;
      if (a == b) { r0 = 1; } e0 = 1; record(); }

    // T7: 1.5 == 2.0 → FALSE (stub falsely says TRUE today)
    { clear(); double a = 1.5d; double b = 2.0d;
      if (a == b) { r0 = 1; } e0 = 0; record(); }

    // T8: 1.5 != 2.0 → TRUE (stub falsely says FALSE today)
    { clear(); double a = 1.5d; double b = 2.0d;
      if (a != b) { r0 = 1; } e0 = 1; record(); }

    // T9: 1.5 != 1.5 → FALSE
    { clear(); double a = 1.5d; double b = 1.5d;
      if (a != b) { r0 = 1; } e0 = 0; record(); }

    // T10: 1.5 <= 1.5 → TRUE (equal case)
    { clear(); double a = 1.5d; double b = 1.5d;
      if (a <= b) { r0 = 1; } e0 = 1; record(); }

    // T11: 1.5 <= 2.0 → TRUE
    { clear(); double a = 1.5d; double b = 2.0d;
      if (a <= b) { r0 = 1; } e0 = 1; record(); }

    // T12: 2.0 <= 1.5 → FALSE
    { clear(); double a = 2.0d; double b = 1.5d;
      if (a <= b) { r0 = 1; } e0 = 0; record(); }

    // T13: 2.0 >= 1.5 → TRUE
    { clear(); double a = 2.0d; double b = 1.5d;
      if (a >= b) { r0 = 1; } e0 = 1; record(); }

    // T14: 1.5 >= 1.5 → TRUE (equal case)
    { clear(); double a = 1.5d; double b = 1.5d;
      if (a >= b) { r0 = 1; } e0 = 1; record(); }

    // T15: negative signs — -3.0 < 1.5 → TRUE
    { clear(); double a = -3.0d; double b = 1.5d;
      if (a < b) { r0 = 1; } e0 = 1; record(); }
}

// ── (float)double cast (T16-T17) ─────────────────────────────────
void testFloatCasts(void)
{
    // T16: (float)1.5d → 5-byte 1.5f. Read via asm to read raw
    //      bytes of the local; the extra 3 slots stay zero.
    {
        clear();
        double d = 1.5d;
        float f = (float)d;
        asm {
            LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4
        }
        e0 = $00; e1 = $00; e2 = $80; e3 = $00; e4 = $00;
        record();
    }

    // T17: (float)-3.0d → 5-byte -3.0f
    {
        clear();
        double d = -3.0d;
        float f = (float)d;
        asm {
            LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4
        }
        e0 = $01; e1 = $01; e2 = $80; e3 = $00; e4 = $00;
        record();
    }
}

// ── (double)float cast (T18-T19) ─────────────────────────────────
void testDoubleCasts(void)
{
    // T18: (double)1.5 → 8-byte 1.5d. Float top 3 mantissa bytes
    //      copy into double top 3; low 3 zero.
    {
        clear();
        float f = 1.5;
        double d = (double)f;
        asm {
            LDA d   : STA r0
            LDA d+1 : STA r1
            LDA d+2 : STA r2
            LDA d+3 : STA r3
            LDA d+4 : STA r4
            LDA d+5 : STA r5
            LDA d+6 : STA r6
            LDA d+7 : STA r7
        }
        e0 = $00; e1 = $00; e2 = $80; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    // T19: (double)-3.0 → 8-byte -3.0d
    {
        clear();
        float f = -3.0;
        double d = (double)f;
        asm {
            LDA d   : STA r0
            LDA d+1 : STA r1
            LDA d+2 : STA r2
            LDA d+3 : STA r3
            LDA d+4 : STA r4
            LDA d+5 : STA r5
            LDA d+6 : STA r6
            LDA d+7 : STA r7
        }
        e0 = $01; e1 = $01; e2 = $80; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }
}

// ── Mixed float + double arithmetic (T20-T23) ────────────────────
void testMixedArith(void)
{
    // T20: 1.5f + 1.5d → 3.0d (float LHS promotes)
    {
        clear();
        float f = 1.5;
        double a = 1.5d;
        double c = f + a;
        asm {
            LDA c   : STA r0
            LDA c+1 : STA r1
            LDA c+2 : STA r2
            LDA c+3 : STA r3
            LDA c+4 : STA r4
            LDA c+5 : STA r5
            LDA c+6 : STA r6
            LDA c+7 : STA r7
        }
        e0 = $00; e1 = $01; e2 = $80; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    // T21: 1.5d + 1.5f → 3.0d (float RHS promotes)
    {
        clear();
        float f = 1.5;
        double a = 1.5d;
        double c = a + f;
        asm {
            LDA c   : STA r0
            LDA c+1 : STA r1
            LDA c+2 : STA r2
            LDA c+3 : STA r3
            LDA c+4 : STA r4
            LDA c+5 : STA r5
            LDA c+6 : STA r6
            LDA c+7 : STA r7
        }
        e0 = $00; e1 = $01; e2 = $80; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    // T22: 2.0d * 1.5f → 3.0d (mul with float RHS)
    {
        clear();
        float f = 1.5;
        double a = 2.0d;
        double c = a * f;
        asm {
            LDA c   : STA r0
            LDA c+1 : STA r1
            LDA c+2 : STA r2
            LDA c+3 : STA r3
            LDA c+4 : STA r4
            LDA c+5 : STA r5
            LDA c+6 : STA r6
            LDA c+7 : STA r7
        }
        e0 = $00; e1 = $01; e2 = $80; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    // T23: 6.0d / 2.0f → 3.0d (div with float RHS)
    {
        clear();
        float f = 2.0;
        double a = 6.0d;
        double c = a / f;
        asm {
            LDA c   : STA r0
            LDA c+1 : STA r1
            LDA c+2 : STA r2
            LDA c+3 : STA r3
            LDA c+4 : STA r4
            LDA c+5 : STA r5
            LDA c+6 : STA r6
            LDA c+7 : STA r7
        }
        e0 = $00; e1 = $01; e2 = $80; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }
}

void main(void)
{
    testCount = 0;
    failCount = 0;

    testComparisons();
    testFloatCasts();
    testDoubleCasts();
    testMixedArith();

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}