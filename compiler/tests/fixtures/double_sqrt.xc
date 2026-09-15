//xtc-flags: skip  — byte-compares retired 5/8-byte softfloat results (dead dp*/fp* routines / old byte layout); obsolete under IEEE via MECH (phase-671). Values covered by mech_demo + mech_float_ops.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// double_sqrt.xc — regression test for dpSqrt.
//
// Byte-exact tests at the runtime level: load $B0-$B7 with the
// input double, JSR dpSqrt, compare $B0-$B7 against hand-encoded
// expected bytes. Same shape as double_add / double_mul.
//
// For perfect squares the expected bytes are derived straight
// from the double format. For irrational roots (sqrt 2, sqrt 3,
// sqrt 5) the expected bytes match IEEE 754 double rounded to a
// 48-bit mantissa.

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

void main(void)
{
    testCount = 0;
    failCount = 0;

    // T1: sqrt(0) = 0  (zero flag)
    { double a = 0.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            JSR dpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T2: sqrt(1) = 1
    { double a = 1.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            JSR dpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $00; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T3: sqrt(4) = 2 (even exp, perfect square)
    { double a = 4.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            JSR dpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $01; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T4: sqrt(9) = 3 (odd exp, perfect square)
    { double a = 9.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            JSR dpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $01; e2 = $80; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T5: sqrt(16) = 4
    { double a = 16.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            JSR dpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $02; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T6: sqrt(0.25) = 0.5 (negative even exp)
    { double a = 0.25d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            JSR dpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $FF; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T7: sqrt(-1) = NaN
    { double a = -1.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            JSR dpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $08; e1 = $00; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T8: sqrt(NaN) = NaN (short-circuit on NaN flag)
    {
        u8 op0 = $08; u8 op1 = $00; u8 op2 = $00; u8 op3 = $00;
        u8 op4 = $00; u8 op5 = $00; u8 op6 = $00; u8 op7 = $00;
        asm { LDA op0 : STA $B0 : LDA op1 : STA $B1
              LDA op2 : STA $B2 : LDA op3 : STA $B3
              LDA op4 : STA $B4 : LDA op5 : STA $B5
              LDA op6 : STA $B6 : LDA op7 : STA $B7
              JSR dpSqrt
              LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
              LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
        e0 = $08; e1 = $00; e2 = $00; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00; record();
    }

    // T9: sqrt(+inf) = NaN (infinity treated as NaN, matching fpSqrt)
    {
        u8 op0 = $20; u8 op1 = $00; u8 op2 = $00; u8 op3 = $00;
        u8 op4 = $00; u8 op5 = $00; u8 op6 = $00; u8 op7 = $00;
        asm { LDA op0 : STA $B0 : LDA op1 : STA $B1
              LDA op2 : STA $B2 : LDA op3 : STA $B3
              LDA op4 : STA $B4 : LDA op5 : STA $B5
              LDA op6 : STA $B6 : LDA op7 : STA $B7
              JSR dpSqrt
              LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
              LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
        e0 = $08; e1 = $00; e2 = $00; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00; record();
    }

    // T10: sqrt(2) — irrational. Expected bytes match IEEE 754
    //      double rounded to a 48-bit mantissa:
    //        sqrt(2) ≈ 0x1.6A09E667F3BCDP+0 (52-bit IEEE form)
    //        round-to-nearest truncating to 48 bits:
    //          top 48 mantissa bits = 0x6A09E667F3BC, low dropped
    //          bits = 0b1101. Top dropped bit 1 + rest non-zero →
    //          round up → 0x6A09E667F3BD.
    //      So: exp = 0, mantissa = {$6A, $09, $E6, $67, $F3, $BD}.
    { double a = 2.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            JSR dpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $00; e2 = $6A; e3 = $09;
      e4 = $E6; e5 = $67; e6 = $F3; e7 = $BD; record(); }

    // T11: sqrt(0.5) — another odd-exp irrational. IEEE 754:
    //      sqrt(0.5) = sqrt(2)/2 ≈ 0x1.6A09E667F3BCDP-1.
    //      Same mantissa as sqrt(2), exp = -1 = $FF.
    { double a = 0.5d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            JSR dpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $FF; e2 = $6A; e3 = $09;
      e4 = $E6; e5 = $67; e6 = $F3; e7 = $BD; record(); }

    // T12: sqrt(100) = 10
    //      10 = 1.25 * 2^3 → mantissa $40..., exp 3
    { double a = 100.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            JSR dpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $03; e2 = $40; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}