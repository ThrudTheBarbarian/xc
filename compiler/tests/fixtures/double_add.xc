//xtc-flags: skip  — byte-compares retired 5/8-byte softfloat results (dead dp*/fp* routines / old byte layout); obsolete under IEEE via MECH (phase-671). Values covered by mech_demo + mech_float_ops.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// double_add.xc — regression test for dpAdd / dpSub runtime routines.
//
// Runtime-level byte-exact tests: load $B0-$BF with two doubles,
// JSR the routine, compare $B0-$B7 bytes against hand-encoded
// expected values. Mirrors float_arith.xc's fpAdd/fpSub blocks.
//
// Format reference:
//    0.0   = {$10, $00, $00, $00, $00, $00, $00, $00}
//    1.0   = {$00, $00, $00, $00, $00, $00, $00, $00}
//    1.5   = {$00, $00, $80, $00, $00, $00, $00, $00}
//    2.0   = {$00, $01, $00, $00, $00, $00, $00, $00}
//    2.5   = {$00, $01, $40, $00, $00, $00, $00, $00}
//    3.0   = {$00, $01, $80, $00, $00, $00, $00, $00}
//    4.0   = {$00, $02, $00, $00, $00, $00, $00, $00}
//    5.0   = {$00, $02, $40, $00, $00, $00, $00, $00}
//   -1.0   = {$01, $00, $00, $00, $00, $00, $00, $00}
//   -2.0   = {$01, $01, $00, $00, $00, $00, $00, $00}
//    NaN   = {$08, $00, $00, $00, $00, $00, $00, $00}

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

    // ── dpAdd ────────────────────────────────────────────────────

    // T1: 1.0 + 1.0 = 2.0
    { double a = 1.0d; double b = 1.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
            LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
            JSR dpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $01; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T2: 2.0 + 2.0 = 4.0
    { double a = 2.0d; double b = 2.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
            LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
            JSR dpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $02; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T3: 1.5 + 1.5 = 3.0 (same exp, mantissa bit carries)
    { double a = 1.5d; double b = 1.5d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
            LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
            JSR dpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $01; e2 = $80; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T4: 1.0 + 2.0 = 3.0 (unequal exp, op1 smaller, op1 shifts right)
    { double a = 1.0d; double b = 2.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
            LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
            JSR dpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $01; e2 = $80; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T5: 2.0 + 1.0 = 3.0 (unequal exp, op2 smaller, op2 shifts right)
    { double a = 2.0d; double b = 1.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
            LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
            JSR dpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $01; e2 = $80; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T6: 0.0 + 5.0 = 5.0 (zero-op1 short-circuit)
    { double a = 0.0d; double b = 5.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
            LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
            JSR dpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $02; e2 = $40; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T7: 5.0 + 0.0 = 5.0 (zero-op2 short-circuit)
    { double a = 5.0d; double b = 0.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
            LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
            JSR dpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $02; e2 = $40; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T8: 1.0 + -1.0 = 0 (exact cancellation → zero)
    { double a = 1.0d; double b = -1.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
            LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
            JSR dpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T9: -3.0 + 2.0 = -1.0 (mixed-sign subtract, op1 larger magnitude)
    { double a = -3.0d; double b = 2.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
            LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
            JSR dpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $01; e1 = $00; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T10: 2.0 + -3.0 = -1.0 (mixed-sign subtract, op2 larger → flip)
    { double a = 2.0d; double b = -3.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
            LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
            JSR dpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $01; e1 = $00; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T11: NaN + 2.0 = NaN
    {
        u8 op1_0 = $08; u8 op1_1 = $00; u8 op1_2 = $00; u8 op1_3 = $00;
        u8 op1_4 = $00; u8 op1_5 = $00; u8 op1_6 = $00; u8 op1_7 = $00;
        double b = 2.0d;
        asm { LDA op1_0 : STA $B0 : LDA op1_1 : STA $B1
              LDA op1_2 : STA $B2 : LDA op1_3 : STA $B3
              LDA op1_4 : STA $B4 : LDA op1_5 : STA $B5
              LDA op1_6 : STA $B6 : LDA op1_7 : STA $B7
              LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
              LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
              JSR dpAdd
              LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
              LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
        e0 = $08; e1 = $00; e2 = $00; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00; record();
    }

    // ── dpSub ────────────────────────────────────────────────────

    // T12: 5.0 - 3.0 = 2.0
    { double a = 5.0d; double b = 3.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
            LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
            JSR dpSub
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $00; e1 = $01; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T13: 3.0 - 5.0 = -2.0
    { double a = 3.0d; double b = 5.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
            LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
            JSR dpSub
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $01; e1 = $01; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T14: 3.0 - 3.0 = 0
    { double a = 3.0d; double b = 3.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
            LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
            JSR dpSub
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T15: 0 - 0 = +0 (sign preservation — must not flip sign of zero op2)
    { double a = 0.0d; double b = 0.0d;
      asm { LDA a   : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3
            LDA a+4 : STA $B4 : LDA a+5 : STA $B5 : LDA a+6 : STA $B6 : LDA a+7 : STA $B7
            LDA b   : STA $B8 : LDA b+1 : STA $B9 : LDA b+2 : STA $BA : LDA b+3 : STA $BB
            LDA b+4 : STA $BC : LDA b+5 : STA $BD : LDA b+6 : STA $BE : LDA b+7 : STA $BF
            JSR dpSub
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
            LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}