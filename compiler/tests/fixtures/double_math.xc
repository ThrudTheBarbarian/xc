//xtc-flags: skip  — byte-compares retired 5/8-byte softfloat results (dead dp*/fp* routines / old byte layout); obsolete under IEEE via MECH (phase-671). Values covered by mech_demo + mech_float_ops.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// double_math.xc — Tier 3 regression for the small dp Math
// overloads that fit any target.
//
// Covered:
//   abs(double) — inline-asm sign-clear.
//
// sin / cos / tan / atan / ln / exp / pow(d, d) all live in
// dedicated fixtures — each carries a large Horner-series
// Taylor body and the combined reachability closure gets tight
// against xt/xe's 16 KB bank page. Splitting keeps abs free
// to regression-test on every target at every opt level.

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

    // T1: abs(1.5d) = 1.5d (already positive, no change)
    { double r = Math.abs(1.5d);
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0 = $00; e1 = $00; e2 = $80; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T2: abs(-1.5d) = 1.5d (sign bit cleared)
    { double r = Math.abs(-1.5d);
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0 = $00; e1 = $00; e2 = $80; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    // T3: abs(0.0d) = 0.0d (zero flag preserved, sign cleared)
    { double r = Math.abs(0.0d);
      asm { LDA r   : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2 : LDA r+3 : STA r3
            LDA r+4 : STA r4 : LDA r+5 : STA r5 : LDA r+6 : STA r6 : LDA r+7 : STA r7 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00;
      e4 = $00; e5 = $00; e6 = $00; e7 = $00; record(); }

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}