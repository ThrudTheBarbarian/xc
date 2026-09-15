//xtc-flags: skip  — byte-compares retired 5/8-byte softfloat results (dead dp*/fp* routines / old byte layout); obsolete under IEEE via MECH (phase-671). Values covered by mech_demo + mech_float_ops.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// double_math_trig.xc — full-precision dp sin / cos / tan / atan.
//
// Each of these methods carries a Horner Taylor body. sin / cos
// use a 12-term series on x² plus range-reduction folds; atan
// uses an 18-term series on y² after a two-stage argument fold
// (reciprocal for |x| > 1, then (x-1)/(x+1) shift for x > √2-1).
// Split off from double_math.xc so the reachability closure
// stays under the xt/xe 16 KB bank-page budget at O0.

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

    // T1: sin(0) = 0. Zero-flag short-circuit path.
    {
        double d = Math.sin(0.0d);
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $10; e1 = $00; e2 = $00; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    // T2: sin(π/2) = 1 exact. Range-reduce is a no-op (π/2 is
    //     already in the target interval); the Taylor series
    //     at π/2 lands on 1.0 in the final ULP.
    {
        double d = Math.sin(Math.PI_2());
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $00; e1 = $00; e2 = $00; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    // T3: cos(0) = 1. Taylor's first term is 1, all others 0.
    {
        double d = Math.cos(0.0d);
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $00; e1 = $00; e2 = $00; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    // T4: cos(π) = -1 exact. Range-reduce folds π to 0 via
    //     cos(π - x), and a final negation flips the sign bit.
    {
        double d = Math.cos(Math.PI());
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $01; e1 = $00; e2 = $00; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    // T5: tan(0) = 0 via sin(0)/cos(0) = 0/1. Zero-flag
    //     preserved through dpDiv.
    {
        double d = Math.tan(0.0d);
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $10; e1 = $00; e2 = $00; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    // T6: atan(0) = 0. Zero-flag short-circuit.
    {
        double d = Math.atan(0.0d);
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $10; e1 = $00; e2 = $00; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    // T7: atan(1) = π/4 exact. Shift fold sends x=1 → 0, Taylor
    //     collapses to 0, result = π/4 + 0. Byte-equals
    //     Math.PI_4().
    {
        double d = Math.atan(1.0d);
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $00; e1 = $FF; e2 = $92; e3 = $1F;
        e4 = $B5; e5 = $44; e6 = $42; e7 = $D2;
        record();
    }

    // T8: atan(-1) = -π/4 exact. Sign bit flipped on the same
    //     mantissa as T7.
    {
        double d = Math.atan(-1.0d);
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $01; e1 = $FF; e2 = $92; e3 = $1F;
        e4 = $B5; e5 = $44; e6 = $42; e7 = $D2;
        record();
    }

    // T9: atan(2) = π/2 - atan(0.5), exercising reciprocal +
    //     shift folds together. Reference value
    //     1.1071487177940904 encodes byte-exact.
    {
        double d = Math.atan(2.0d);
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $00; e1 = $00; e2 = $1B; e3 = $6E;
        e4 = $19; e5 = $2E; e6 = $BB; e7 = $E4;
        record();
    }

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}