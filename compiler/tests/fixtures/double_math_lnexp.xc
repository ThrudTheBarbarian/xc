//xtc-flags: skip  — byte-compares retired 5/8-byte softfloat results (dead dp*/fp* routines / old byte layout); obsolete under IEEE via MECH (phase-671). Values covered by mech_demo + mech_float_ops.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// double_math_lnexp.xc — full-precision dp ln / exp / pow(d, d).
//
// These three methods hold the Horner-series Taylor approximations
// directly in their class-method bodies (15-term atanh for ln, 18-
// term Taylor for exp, pow(d, d) = exp(p * ln(v))). Together
// they're ~8 KB of compiled code, which overflows xl's 32 KB flat
// code region. Split off from double_math.xc so the smaller dp
// overloads (abs, sin / cos / tan / atan) can still be regression-
// tested on every target.
//
// Runs on xl / xt / xe at all opt levels — the dp results are
// byte-exact across targets.

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

    // T1: ln(1.0d) = 0 (zero-flag short-circuit path — u = 0 so
    //     the atanh series collapses; k = 0 so the k*ln(2) term
    //     also collapses).
    {
        double d = Math.ln(1.0d);
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $10; e1 = $00; e2 = $00; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    // T2: ln(2.0d) — full-precision ln, exact match against the
    //     Math.LN2() dp constant ($00 $FF $62 $E4 $2F $EF $A3 $9F).
    //     The k*ln(2) shortcut produces this exactly: m = 1 after
    //     exp-zeroing, series is 0, result is 1 * ln(2).
    {
        double d = Math.ln(2.0d);
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $00; e1 = $FF; e2 = $62; e3 = $E4;
        e4 = $2F; e5 = $EF; e6 = $A3; e7 = $9F;
        record();
    }

    // T3: ln(Math.E()) = 1.0. Real dp precision — the E constant
    //     encoded at 48 bits round-trips through the log algorithm
    //     to exactly 1.0d.
    {
        double d = Math.ln(Math.E());
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $00; e1 = $00; e2 = $00; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    // T4: exp(0.0d) = 1.0 (Taylor series' first term is 1, all
    //     subsequent terms are 0).
    {
        double d = Math.exp(0.0d);
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $00; e1 = $00; e2 = $00; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    // T5: exp(1.0d) — full-precision, matches Math.E() exactly
    //     (the 18-term Taylor series hits the dp ULP in the last
    //     term, landing on the exact encoding of e).
    {
        double d = Math.exp(1.0d);
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $00; e1 = $01; e2 = $5B; e3 = $F0;
        e4 = $A8; e5 = $B1; e6 = $45; e7 = $77;
        record();
    }

    // T6: exp(Math.LN2()) = 2.0 exact. The range-reduction halves
    //     LN2 once (it's already ≤ 1), Taylor on 0.346… gives
    //     ≈ sqrt(2), and the final square yields exactly 2.
    {
        double d = Math.exp(Math.LN2());
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $00; e1 = $01; e2 = $00; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    // T7: pow(1.0d, 2.0d) = 1 exact via the exp(0) = 1 short-
    //     circuit (ln(1) = 0 → exp(0) = 1). Arbitrary pow(d, d)
    //     cases accumulate a few ULPs of error through ln+exp
    //     and aren't byte-exact; this test pins the lossless
    //     special case.
    {
        double d = Math.pow(1.0d, 2.0d);
        asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
              LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
        e0 = $00; e1 = $00; e2 = $00; e3 = $00;
        e4 = $00; e5 = $00; e6 = $00; e7 = $00;
        record();
    }

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}