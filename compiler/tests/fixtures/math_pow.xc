//xtc-flags: skip  — byte-compares retired 5/8-byte softfloat results (dead dp*/fp* routines / old byte layout); obsolete under IEEE via MECH (phase-671). Values covered by mech_demo + mech_float_ops.
// math_pow.xc — regression test for Math.pow with integer exponent.
//
// The i16-exponent overload uses binary exponentiation (square-and-
// multiply) and produces exact results because there's no series
// approximation — every operation is a native fpMul. That lets us
// byte-compare the results against the natural float encoding of each
// product.
//
// Kept as a dedicated fixture (rather than folded into float_arith.xc)
// because importing Math.xc pulls in all its methods at -O0 (~16 KB
// of extra code for trig / sqrt / constants / etc.) and float_arith
// is already close to the xl code-region ceiling.

// Uses the Atari-only Math library (6502-asm float pack); no arm64
// equivalent, so this runs on the xt6502 backend only.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
#import "Stdio.xc"
#import "Math.xc"

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

u8 testCount;
u8 failCount;
u8 fails[16];

void record(void)
{
    testCount = testCount + 1;
    if (r0 != e0 || r1 != e1 || r2 != e2 || r3 != e3 || r4 != e4) {
        if (failCount < 16) { fails[failCount] = testCount; }
        failCount = failCount + 1;
    }
}

void main(void)
{
    testCount = 0;
    failCount = 0;

    // ── Basic positive integer exponents ───────────────────────
    // pow(2, 0) = 1.0 = 1.0 * 2^0. Fast-exit path for zero exponent.
    { float f = Math.pow(2.0, 0);
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      e0 = $00; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // pow(2, 1) = 2.0 = 1.0 * 2^1. Smallest non-trivial case.
    { float f = Math.pow(2.0, 1);
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $00; e3 = $00; e4 = $00; record(); }

    // pow(2, 2) = 4.0 = 1.0 * 2^2. Tests the square-only path.
    { float f = Math.pow(2.0, 2);
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $00; e3 = $00; e4 = $00; record(); }

    // pow(2, 3) = 8.0 = 1.0 * 2^3. First case that does a conditional mul.
    { float f = Math.pow(2.0, 3);
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      e0 = $00; e1 = $03; e2 = $00; e3 = $00; e4 = $00; record(); }

    // pow(2, 10) = 1024.0 = 1.0 * 2^10. Exercises the full O(log n) loop.
    { float f = Math.pow(2.0, 10);
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      e0 = $00; e1 = $0A; e2 = $00; e3 = $00; e4 = $00; record(); }

    // pow(3, 4) = 81.0 = 1.265625 * 2^6 → exp 6, m0 = $44.
    // 1 + 0x44/0x100 = 1.265625; 1.265625 * 64 = 81.0.
    { float f = Math.pow(3.0, 4);
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      e0 = $00; e1 = $06; e2 = $44; e3 = $00; e4 = $00; record(); }

    // pow(1.5, 4) = 5.0625 = 1.265625 * 2^2 → exp 2, m0 = $44.
    { float f = Math.pow(1.5, 4);
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $44; e3 = $00; e4 = $00; record(); }

    // ── Negative integer exponents (1 / result) ────────────────
    // pow(2, -1) = 0.5 = 1.0 * 2^-1.
    { float f = Math.pow(2.0, -1);
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      e0 = $00; e1 = $FF; e2 = $00; e3 = $00; e4 = $00; record(); }

    // pow(2, -3) = 0.125 = 1.0 * 2^-3.
    { float f = Math.pow(2.0, -3);
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      e0 = $00; e1 = $FD; e2 = $00; e3 = $00; e4 = $00; record(); }

    // ── Base edge case: 0^n ────────────────────────────────────
    // pow(0, 5) = 0.0 (zero-flag encoding: $10, rest 0).
    { float f = Math.pow(0.0, 5);
      asm { LDA f : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2
            LDA f+3 : STA r3 : LDA f+4 : STA r4 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}
