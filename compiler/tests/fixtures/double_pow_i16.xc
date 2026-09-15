//xtc-flags: skip  — byte-compares retired 5/8-byte softfloat results (dead dp*/fp* routines / old byte layout); obsolete under IEEE via MECH (phase-671). Values covered by mech_demo + mech_float_ops.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// double_pow_i16.xc — regression for full-precision Math.pow(double, i16).
//
// The pow(double, i16) overload only compiles when ENABLE_DOUBLE=1
// (memory budget allows the dpMul runtime). It does binary
// exponentiation on a double base, producing the exact 48-bit-
// mantissa product at each squaring step. This fixture pins down
// the byte-exact outputs so regressions in dpMul or the Math-side
// call convention show up cleanly.
//
// The fixture is O3-only on xl (memory constraint), all O levels on
// banked. run_fixtures.sh handles the matrix.

#import "Stdio.xc"
#import "Math.xc"

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

    // T1: 2^0 = 1
    { double r = Math.pow(2.0d, 0);
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0 = $00; e1 = $00; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T2: 2^1 = 2
    { double r = Math.pow(2.0d, 1);
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0 = $00; e1 = $01; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T3: 2^3 = 8  = 1 * 2^3
    { double r = Math.pow(2.0d, 3);
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0 = $00; e1 = $03; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T4: 2^10 = 1024 = 1 * 2^10
    { double r = Math.pow(2.0d, 10);
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0 = $00; e1 = $0A; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T5: 3^4 = 81 = 1.265625 * 2^6 = (1 + 0.265625) * 64
    //     0.265625 = 17/64 = 0b010001 → top bits $44 at mantissa byte 0
    { double r = Math.pow(3.0d, 4);
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0 = $00; e1 = $06; e2 = $44; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T6: 2^-1 = 0.5
    { double r = Math.pow(2.0d, -1);
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0 = $00; e1 = $FF; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T7: 0^5 = 0
    { double r = Math.pow(0.0d, 5);
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T8: anything^0 = 1 (even 0^0 — the short-circuit catches it
    //     before the val==0 check, matching pow(float, i16) behaviour)
    { double r = Math.pow(5.0d, 0);
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0 = $00; e1 = $00; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T9: pow(double, i32) — wider-exponent overload, same result
    //     as pow(double, i16) for small values. 2^10 = 1024 via i32.
    { i32 p = 10;
      double r = Math.pow(2.0d, p);
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0 = $00; e1 = $0A; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T10: pow(double, u32) — unsigned exponent overload. 3^4 = 81.
    { u32 p = 4;
      double r = Math.pow(3.0d, p);
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0 = $00; e1 = $06; e2 = $44; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}