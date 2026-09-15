//xtc-flags: skip  — byte-compares the retired 5-byte softfloat runtime layout; obsolete under IEEE (MECH migration, phase-671). IEEE float behaviour is covered by mech_demo + printf* fixtures.
// float_arith.xc — regression test for the 5-byte float runtime
// AND a spot-check of the compiler features layered on top of it.
//
// Each test lives in a `{ ... }` block that writes a 10-byte
// record through `bufPtr` (5 bytes "got", 5 bytes "expected").
// The buffer starts at $9000; the tests.run_float_arith.py runner
// compiles, loads the xex under py65, executes until BRK, reads
// testCount, and walks the buffer, printing per-test PASS/FAIL.
//
// Test style. The file mixes two complementary patterns:
//
//   (a) Runtime-level tests JSR the fp routine directly from an
//       inline `asm { ... }` block, loading $B0..$B9 with known
//       byte patterns and comparing the post-call $B0..$B4 against
//       hand-encoded expected bytes. This is the only way to get a
//       byte-exact check on the routine's actual behaviour, without
//       any compiler layer in between. fpMul/fpAdd/fpSub/fpDiv/
//       fpSqrt/fpMod/asc2fp/fp2Asc/fpSin/fpCos/fpTan/fpAtan/fpCmp
//       are all tested this way.
//
//   (b) Compiler-level tests use ordinary xtc syntax — `c = a * b;`,
//       `if (a < b)`, `Five v = make_five(10);` — to exercise the
//       codegen's float operator lowering, float call-return
//       convention, float parameter passing, float comparisons,
//       and struct return (small and large paths). These run in
//       the same fixture so a bug in the shared $B0..$BC runtime
//       window shows up as a cascade of failures in both groups.
//
// Early in the project (a) was the only option because the float
// compiler support was broken or missing; today both work. We keep
// the runtime-level tests even where the compiler could emit the
// same sequence, because a bug in the compiler's operator codegen
// shouldn't mask a regression in the runtime routine itself.
//
// Format reference (implicit-leading-1, flag bits in byte 0):
//    bit 0 = sign, 1 = uflow, 2 = oflow, 3 = NaN,
//    bit 4 = zero,  5 = infinity
//
//    0.0 = {$10, $00, $00, $00, $00}
//    1.0 = {$00, $00, $00, $00, $00}   1 * 2^0 (mantissa frac = 0)
//    1.5 = {$00, $00, $80, $00, $00}   1.5 * 2^0 (frac = 0.5)
//    2.0 = {$00, $01, $00, $00, $00}   1 * 2^1
//    2.25= {$00, $01, $20, $00, $00}   1.125 * 2^1 (frac = 0.125)
//    3.0 = {$00, $01, $80, $00, $00}   1.5 * 2^1
//    4.0 = {$00, $02, $00, $00, $00}   1 * 2^2
//    5.0 = {$00, $02, $40, $00, $00}   1.25 * 2^2 (frac = 0.25)
//    6.0 = {$00, $02, $80, $00, $00}   1.5 * 2^2
//    9.0 = {$00, $03, $20, $00, $00}   1.125 * 2^3 (frac = 0.125)
//    0.5 = {$00, $FF, $00, $00, $00}   1 * 2^-1
//   -1.0 = {$01, $00, $00, $00, $00}
//   -3.0 = {$01, $01, $80, $00, $00}
//   +inf = {$20, $00, $00, $00, $00}
//   -inf = {$21, $00, $00, $00, $00}
//    NaN = {$08, $00, $00, $00, $00}
//
// fpDiv: finite/0 returns ±inf (sign = dividend^divisor); 0/0
// returns NaN. fpTan: angle within ε of ±π/2 returns ±inf.
// Everywhere else: an infinity operand promotes the result to NaN.

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

// Split into one function per section and tagged xt6502: a single
// 130+-block main overflows the xt6502 unbanked code budget and can't be
// bank-split (banking is function-granularity), and the $B0-mailbox float
// staging below is 6502 inline asm the arm64 reference backend can't run.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
#import "Stdio.xc"

u8 testCount;
u8 failCount;

// Strings for the asc2fp round-trip tests. The parser takes a
// null-terminated ATASCII pointer, so each array ends in $00.
u8 asc_3[]      = {$33, $00};                                // "3"
u8 asc_m42[]    = {$2D, $34, $32, $00};                      // "-42"
u8 asc_pi[]     = {$33, $2E, $31, $34, $00};                 // "3.14"
u8 asc_half[]   = {$2E, $35, $00};                           // ".5"
u8 asc_1500[]   = {$31, $2E, $35, $65, $33, $00};            // "1.5e3"
u8 asc_tiny[]   = {$32, $2E, $35, $65, $2D, $32, $00};       // "2.5e-2"
u8 asc_zero[]   = {$30, $00};                                // "0"
u8 asc_long[]   = {$31, $32, $33, $34, $35, $36, $37, $00};  // "1234567"
u8 asc_inf[]    = {$69, $6E, $66, $00};                       // "inf"
u8 asc_ninf[]   = {$2D, $69, $6E, $66, $00};                  // "-inf"
u8 asc_nan[]    = {$6E, $61, $6E, $00};                       // "nan"
u8 asc_INF[]    = {$49, $4E, $46, $00};                       // "INF"
u8 asc_Inf[]    = {$49, $6E, $66, $00};                       // "Inf"
u8 asc_NAN[]    = {$4E, $41, $4E, $00};                       // "NAN"
u8 asc_NaN[]    = {$4E, $61, $4E, $00};                       // "NaN"

// Compare r0..r4 (got) byte-wise against e0..e4 (expected). On
// mismatch just bump failCount — the FAIL lines are printed once
// at the end of main() by dumping a small circular buffer of
// failing test numbers. This keeps printf out of the hot loop,
// which matters: the 130-call record()/recordP() path lives inside
// main() and printf here would put enough register pressure on
// main's frame to force float locals into spill slots, where the
// spilled-float-return codegen path (a latent bug) only writes 2
// of the 5 bytes and every float-convention test comes back zero.
u8 fails[16];

void record(void)
{
    testCount = testCount + 1;
    if (r0 != e0 || r1 != e1 || r2 != e2 || r3 != e3 || r4 != e4) {
        if (failCount < 16) { fails[failCount] = testCount; }
        failCount = failCount + 1;
    }
}

// Same as `record` but takes the expected bytes as parameters —
// a regression test for the "multi-u8 parameters push in wrong
// order" bug (if any parameter ends up in the wrong slot, the
// comparison here will flag it).
void recordP(u8 p0, u8 p1, u8 p2, u8 p3, u8 p4)
{
    testCount = testCount + 1;
    if (r0 != p0 || r1 != p1 || r2 != p2 || r3 != p3 || r4 != p4) {
        if (failCount < 16) { fails[failCount] = testCount; }
        failCount = failCount + 1;
    }
}

// ── Float register-result convention helpers ─────────────────────
// These exercise the 5-byte float return/argument convention:
//   • fadd / fmul take two float params and return a float, so both
//     the inbound parameter passing and the outbound return flow
//     through the $B0..$B4 register-result slot.
//   • fdouble nests one float call inside another's argument list
//     when combined with the expression-argument path.
float fadd(float a, float b)     { return a + b; }
float fmul(float a, float b)     { return a * b; }
float fdouble(float x)           { return x * 2.0; }

// ── Small-struct return helpers ─────────────────────────────────
// A 5-byte struct fits exactly in the 5-byte record slot, so we
// use these directly in the fixture to test the small-struct
// register-result convention end-to-end.
struct Five {
    u8 a;
    u8 b;
    u8 c;
    u8 d;
    u8 e;
}

Five make_five(u8 seed) {
    Five f;
    f.a = seed;
    f.b = seed + 1;
    f.c = seed + 2;
    f.d = seed + 3;
    f.e = seed + 4;
    return f;
}

// ── Large-struct return helper (> 8 bytes → hidden __retbuf) ───
// A 12-byte struct exercises the lowering path: the function gets
// rewritten to take `__retbuf : *Twelve` as its hidden first arg,
// the `return` emits a byte-by-byte copy through it, and the
// caller pushes &dest as the first arg at the call site.
struct Twelve {
    u8 v0; u8 v1; u8 v2;  u8 v3;
    u8 v4; u8 v5; u8 v6;  u8 v7;
    u8 v8; u8 v9; u8 vA;  u8 vB;
}

Twelve make_twelve(u8 seed) {
    Twelve t;
    t.v0 = seed;
    t.v1 = seed + 1;
    t.v2 = seed + 2;
    t.v3 = seed + 3;
    t.v4 = seed + 4;
    t.v5 = seed + 5;
    t.v6 = seed + 6;
    t.v7 = seed + 7;
    t.v8 = seed + 8;
    t.v9 = seed + 9;
    t.vA = seed + 10;
    t.vB = seed + 11;
    return t;
}

// Intentionally NOT exercised here: passing a struct by value as
// a function parameter (e.g. `Five copy_five(Five src)`). That's a
// separate codegen path that hasn't been audited — add tests when
// it is.


void t_s1(void)
{
    // ── fpMul ────────────────────────────────────────────────────
    // Tests the rewritten multiply, including the zero-flag fast
    // paths and power-of-two mantissas that used to hang normalise.

    { float a = 1.0; float b = 1.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMul
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 1.0; float b = 2.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMul
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 2.0; float b = 2.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMul
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 1.5; float b = 2.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMul
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $80; e3 = $00; e4 = $00; record(); }

    { float a = 1.5; float b = 1.5;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMul
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $20; e3 = $00; e4 = $00; record(); }

    { float a = 3.0; float b = 2.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMul
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $80; e3 = $00; e4 = $00; record(); }

    { float a = 0.0; float b = 5.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMul
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 5.0; float b = 0.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMul
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 0.0; float b = 0.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMul
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = -3.0; float b = 2.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMul
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $01; e1 = $02; e2 = $80; e3 = $00; e4 = $00; record(); }

    { float a = -1.0; float b = -1.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMul
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

}

void t_s2(void)
{
    // ── fpAdd ────────────────────────────────────────────────────
    // Same-sign adds always carry out of the mantissa top; cancelling
    // subtracts land on the zero-result guard that replaced the old
    // BMI normalise-loop hang; zero short-circuits cover the flag.

    { float a = 1.0; float b = 1.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 1.5; float b = 1.5;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $80; e3 = $00; e4 = $00; record(); }

    { float a = 3.0; float b = 3.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $80; e3 = $00; e4 = $00; record(); }

    { float a = 3.0; float b = -3.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 3.0; float b = -1.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 0.0; float b = 5.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $40; e3 = $00; e4 = $00; record(); }

    { float a = 5.0; float b = 0.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $40; e3 = $00; e4 = $00; record(); }

    { float a = 0.0; float b = 0.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpAdd
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

}

void t_s3(void)
{
    // ── fpSub ────────────────────────────────────────────────────
    // fpSub flips op2's sign bit and tail-calls fpAdd.

    { float a = 3.0; float b = 1.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpSub
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 1.0; float b = 3.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpSub
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $01; e1 = $01; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 5.0; float b = 5.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpSub
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 5.0; float b = 0.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpSub
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $40; e3 = $00; e4 = $00; record(); }

    { float a = 0.0; float b = 5.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpSub
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $01; e1 = $02; e2 = $40; e3 = $00; e4 = $00; record(); }

}

void t_s4(void)
{
    // ── fpDiv ────────────────────────────────────────────────────
    // Divide-by-zero priority, zero dividend, exact quotients.

    { float a = 2.0; float b = 2.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpDiv
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 1.0; float b = 2.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpDiv
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $FF; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 3.0; float b = 2.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpDiv
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $00; e2 = $80; e3 = $00; e4 = $00; record(); }

    { float a = 6.0; float b = 3.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpDiv
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 0.0; float b = 5.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpDiv
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 5.0; float b = 0.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpDiv
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // 5/0 = +inf
      e0 = $20; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 1.0; float b = 1.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpDiv
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

}

void t_s5(void)
{
    // ── fpSqrt ──────────────────────────────────────────────────
    // The rewritten bit-by-bit sqrt handles all non-power-of-2 inputs
    // correctly. Perfect squares give byte-exact results; sqrt(2) is
    // off by a few ulps (~2e-8) because of 24-bit integer truncation.

    { float a = 0.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            JSR fpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 1.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            JSR fpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 4.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            JSR fpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $00; e3 = $00; e4 = $00; record(); }

    // sqrt(9) = 3.0 — the canonical "hard" case that the old
    // non-restoring algorithm got wrong by ~7% (returned 2.78).
    { float a = 9.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            JSR fpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $80; e3 = $00; e4 = $00; record(); }

    // sqrt(25) = 5.0 — exercises odd-exp path with a non-integer mantissa.
    // 25 = 1.5625 * 2^4 -> {$00,$04,$90,$00,$00}. sqrt = 5.0 =
    // 1.25 * 2^2 -> {$00,$02,$40,$00,$00}.
    { float a = 25.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            JSR fpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $40; e3 = $00; e4 = $00; record(); }

    // sqrt(100) = 10.0. 100 = 1.5625 * 2^6 -> {$00,$06,$90,$00,$00}.
    // 10 = 1.25 * 2^3 -> {$00,$03,$40,$00,$00}.
    { float a = 100.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            JSR fpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $03; e2 = $40; e3 = $00; e4 = $00; record(); }

    // sqrt(0.25) = 0.5 — negative exponent, perfect square.
    // 0.25 = {$00,$FE,$00,$00,$00}, sqrt = {$00,$FF,$00,$00,$00}.
    { float a = 0.25;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            JSR fpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $FF; e2 = $00; e3 = $00; e4 = $00; record(); }

    // sqrt(2) ≈ 1.4142135382 — irrational, not byte-exact with the
    // truncating 24-bit integer sqrt. The bottom 2 bytes differ from
    // a true round-to-nearest, so the expected here matches the
    // truncation exactly: 1 + 0x6A09E6/2^24 = 1.4142135382...
    { float a = 2.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            JSR fpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $00; e1 = $00; e2 = $6A; e3 = $09; e4 = $E6; record(); }

}

void t_s6(void)
{
    // ── Native float operators ───────────────────────────────────
    // Previously `c = a * b` for floats compiled as an integer
    // CLC/ADC sequence and never touched the fp runtime. Now the
    // codegen intercepts float-typed assignments whose RHS is a
    // binary expression and routes through fpAdd/fpSub/fpMul/fpDiv
    // directly. These tests call the operators by their natural
    // syntax instead of poking $B0-$B9 from inline asm.

    { float a = 1.5; float b = 2.0; float c;
      c = a * b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2
            LDA c+3 : STA r3 : LDA c+4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $80; e3 = $00; e4 = $00; record(); }

    { float a = 1.5; float b = 1.5; float c;
      c = a + b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2
            LDA c+3 : STA r3 : LDA c+4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $80; e3 = $00; e4 = $00; record(); }

    { float a = 3.0; float b = 1.0; float c;
      c = a - b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2
            LDA c+3 : STA r3 : LDA c+4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 3.0; float b = 2.0; float c;
      c = a / b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2
            LDA c+3 : STA r3 : LDA c+4 : STA r4 }
      e0 = $00; e1 = $00; e2 = $80; e3 = $00; e4 = $00; record(); }

    // Float-to-float variable copy (no operator, just assignment).
    { float a = 1.5; float c;
      c = a;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2
            LDA c+3 : STA r3 : LDA c+4 : STA r4 }
      e0 = $00; e1 = $00; e2 = $80; e3 = $00; e4 = $00; record(); }

    // Left-nested binop: `(a * b) + c` — the evaluator recurses
    // into the left side first, leaving the product in $B0..$B4,
    // then loads the right terminal into $B5..$B9 and calls fpAdd.
    // (1.5 * 2.0) + 1.0 = 3.0 + 1.0 = 4.0 = {0, 2, 0, 0, 0}.
    { float a = 1.5; float b = 2.0; float c = 1.0; float r;
      r = a * b + c;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $00; e3 = $00; e4 = $00; record(); }

    // Deeper left-nest: ((1 + 1) * 1.5) - 0.5 = 3.0 - 0.5 = 2.5.
    // 2.5 = 1.25 * 2^1 -> frac = 0.25 -> mantissaBits = $400000.
    { float a = 1.0; float b = 1.0; float c = 1.5; float d = 0.5; float r;
      r = (a + b) * c - d;
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $40; e3 = $00; e4 = $00; record(); }

    // Right-nested: a * (b + c). The RHS subexpression would clobber
    // $B0..$B4 while it runs, so the code generator spills the LHS
    // (a, sitting in $B0..$B4) to the 6502 stack, evaluates (b + c)
    // into $B0..$B4, moves that into $B5..$B9, then pops the LHS back
    // into $B0..$B4 before the final fpMul.
    //
    // 1.5 * (1.0 + 1.0) = 1.5 * 2.0 = 3.0 = {0, 1, $80, 0, 0}.
    { float a = 1.5; float b = 1.0; float c = 1.0; float r;
      r = a * (b + c);
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $80; e3 = $00; e4 = $00; record(); }

    // Two levels of right-nesting: a + (b * (c + d)).
    // 1.0 + (0.5 * (1.0 + 1.0)) = 1.0 + (0.5 * 2.0) = 1.0 + 1.0 = 2.0.
    // Exercises nested PHA/PLA pairs — the outer spill saves `a`
    // while the inner spill (under `b *`) saves `b`.
    { float a = 1.0; float b = 0.5; float c = 1.0; float d = 1.0; float r;
      r = a + b * (c + d);
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $00; e3 = $00; e4 = $00; record(); }

    // Both sides nested: (a + b) * (c + d).
    // (1.5 + 0.5) * (1.0 + 1.0) = 2.0 * 2.0 = 4.0 = {0, 2, 0, 0, 0}.
    { float a = 1.5; float b = 0.5; float c = 1.0; float d = 1.0; float r;
      r = (a + b) * (c + d);
      asm { LDA r : STA r0 : LDA r+1 : STA r1 : LDA r+2 : STA r2
            LDA r+3 : STA r3 : LDA r+4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $00; e3 = $00; e4 = $00; record(); }

}

void t_s7(void)
{
    // ── Multi-u8 parameter regression ────────────────────────────
    // Run a trivial multiply whose result is asymmetric in every
    // byte and record through `recordP(u8,u8,u8,u8,u8)`. If the
    // mixed-parameter-order bug comes back, the recorded bytes will
    // be scrambled and the runner will report a FAIL.
    { float a = 1.5; float b = 2.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2
            LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7
            LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMul
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      recordP($00, $01, $80, $00, $00); }

}

void t_s8(void)
{
    // ── asc2fp round-trip ──────────────────────────────────────
    // The rewritten parser handles sign, arbitrary-length integer
    // and fractional parts, and `e`/`E` scientific notation with
    // optional exponent sign. Results are byte-exact when the input
    // is exactly representable, and within a ulp or two when the
    // target value isn't (e.g. "3.14", "2.5e-2").

    { asm { LDA #<asc_3    : STA $B5 : LDA #>asc_3    : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // "3"  = 1.5 * 2^1  -> {$00, $01, $80, $00, $00}
      e0 = $00; e1 = $01; e2 = $80; e3 = $00; e4 = $00; record(); }

    { asm { LDA #<asc_m42  : STA $B5 : LDA #>asc_m42  : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // "-42" = -(1.3125 * 2^5) -> {$01, $05, $50, $00, $00}
      e0 = $01; e1 = $05; e2 = $50; e3 = $00; e4 = $00; record(); }

    { asm { LDA #<asc_pi   : STA $B5 : LDA #>asc_pi   : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // "3.14" — off by 1 ulp (0x91EB82 vs the "true" 0x91EB85 because
      // the integer accumulator can't carry the last fractional digit
      // through the divide-by-100 without a rounding error). Matches
      // Python's own (1 + 0x91EB82/2^24) * 2 = 3.1399996280670166.
      e0 = $00; e1 = $01; e2 = $91; e3 = $EB; e4 = $82; record(); }

    { asm { LDA #<asc_half : STA $B5 : LDA #>asc_half : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // ".5" = 1.0 * 2^-1 -> {$00, $FF, $00, $00, $00}
      e0 = $00; e1 = $FF; e2 = $00; e3 = $00; e4 = $00; record(); }

    { asm { LDA #<asc_1500 : STA $B5 : LDA #>asc_1500 : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // "1.5e3" = 1500.0 = 1.46484375 * 2^10 -> {$00, $0A, $77, $00, $00}
      e0 = $00; e1 = $0A; e2 = $77; e3 = $00; e4 = $00; record(); }

    { asm { LDA #<asc_tiny : STA $B5 : LDA #>asc_tiny : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // "2.5e-2" = 0.025 ≈ 1.6 * 2^-6 -> actual result is 1 ulp below
      // the "true" binary truncation: {$00, $FA, $99, $99, $98}.
      e0 = $00; e1 = $FA; e2 = $99; e3 = $99; e4 = $98; record(); }

    { asm { LDA #<asc_zero : STA $B5 : LDA #>asc_zero : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // "0" -> zero-flagged.
      e0 = $10; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { asm { LDA #<asc_long : STA $B5 : LDA #>asc_long : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // "1234567" = 1.1773681640625 * 2^20 -> {$00, $14, $2D, $68, $70}
      e0 = $00; e1 = $14; e2 = $2D; e3 = $68; e4 = $70; record(); }

    // "inf" -> +infinity
    { asm { LDA #<asc_inf : STA $B5 : LDA #>asc_inf : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $20; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // "-inf" -> -infinity
    { asm { LDA #<asc_ninf : STA $B5 : LDA #>asc_ninf : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $21; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // "nan" -> NaN
    { asm { LDA #<asc_nan : STA $B5 : LDA #>asc_nan : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $08; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // "INF" -> +infinity (case-insensitive)
    { asm { LDA #<asc_INF : STA $B5 : LDA #>asc_INF : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $20; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // "Inf" -> +infinity (mixed case)
    { asm { LDA #<asc_Inf : STA $B5 : LDA #>asc_Inf : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $20; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // "NAN" -> NaN (uppercase)
    { asm { LDA #<asc_NAN : STA $B5 : LDA #>asc_NAN : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $08; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // "NaN" -> NaN (mixed case)
    { asm { LDA #<asc_NaN : STA $B5 : LDA #>asc_NaN : STA $B6 : JSR asc2fp
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2
            LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $08; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // fp2Asc(+inf) -> "inf\0\0" (writes directly into the consecutive
    // r0..r4 global slots; fp2Asc's output is null-terminated, so bytes
    // 3 and 4 are whatever was there plus a trailing $00).
    { asm { LDA #$20 : STA $B0      ; +inf flags
            LDA #$00 : STA $B1 : STA $B2 : STA $B3 : STA $B4
            LDA #$00 : STA r0 : STA r1 : STA r2 : STA r3 : STA r4
            LDA #<r0 : STA $B5 : LDA #>r0 : STA $B6
            JSR fp2Asc }
      // 'i','n','f',null,null
      e0 = $69; e1 = $6E; e2 = $66; e3 = $00; e4 = $00; record(); }

    // fp2Asc(-inf) -> "-inf\0"
    { asm { LDA #$21 : STA $B0      ; -inf flags
            LDA #$00 : STA $B1 : STA $B2 : STA $B3 : STA $B4
            LDA #$00 : STA r0 : STA r1 : STA r2 : STA r3 : STA r4
            LDA #<r0 : STA $B5 : LDA #>r0 : STA $B6
            JSR fp2Asc }
      // '-','i','n','f',null
      e0 = $2D; e1 = $69; e2 = $6E; e3 = $66; e4 = $00; record(); }

    // fp2Asc(NaN) -> "nan\0\0"
    { asm { LDA #$08 : STA $B0      ; NaN flag
            LDA #$00 : STA $B1 : STA $B2 : STA $B3 : STA $B4
            LDA #$00 : STA r0 : STA r1 : STA r2 : STA r3 : STA r4
            LDA #<r0 : STA $B5 : LDA #>r0 : STA $B6
            JSR fp2Asc }
      // 'n','a','n',null,null
      e0 = $6E; e1 = $61; e2 = $6E; e3 = $00; e4 = $00; record(); }

    // fp2Asc(PI) -> "3.14159..." — first 5 chars should be '3','.','1','4','1'
    { asm { LDA #$00 : STA $B0      ; flags
            LDA #$01 : STA $B1      ; exp
            LDA #$92 : STA $B2      ; mantissa
            LDA #$1F : STA $B3
            LDA #$B5 : STA $B4
            LDA #$00 : STA r0 : STA r1 : STA r2 : STA r3 : STA r4
            LDA #<r0 : STA $B5 : LDA #>r0 : STA $B6
            JSR fp2Asc }
      // '3','.','1','4','1'
      e0 = $33; e1 = $2E; e2 = $31; e3 = $34; e4 = $31; record(); }

}

void t_s9(void)
{
    // ── fpMod ───────────────────────────────────────────────────
    // Exercises the rewritten truncation step (the old version
    // "truncated" by zeroing $B3 and $B4 of the quotient mantissa,
    // which only did the right thing when the quotient's fractional
    // bits happened to already be zero — e.g. `5 mod 2` returned 0.)
    //
    // Byte-exact expected values: `x mod y` where the result is an
    // exactly representable float.

    { float a = 5.0; float b = 2.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMod
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // 5 mod 2 = 1.0
      e0 = $00; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 7.0; float b = 3.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMod
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // 7 mod 3 = 1.0
      e0 = $00; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 10.0; float b = 3.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMod
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // 10 mod 3 = 1.0
      e0 = $00; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 4.0; float b = 2.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMod
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // 4 mod 2 = 0.0 (zero-flagged)
      e0 = $10; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 1.5; float b = 1.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMod
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // 1.5 mod 1.0 = 0.5
      e0 = $00; e1 = $FF; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 0.75; float b = 0.5;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMod
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // 0.75 mod 0.5 = 0.25
      e0 = $00; e1 = $FE; e2 = $00; e3 = $00; e4 = $00; record(); }

    { float a = 0.0; float b = 5.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpMod
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      // 0 mod 5 = 0.0 (zero-flagged, clean +0)
      e0 = $10; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

}

void t_s10(void)
{
    // ── fpSin / fpCos / fpTan / fpAtan ──────────────────────────
    // CORDIC trig is inherently approximate (~14 bits of precision)
    // and the original fixture leaned on a Python-side tolerance
    // table to accept the "close-enough" results. After dropping
    // the Python runner the tolerance tests moved to a separate
    // fixture (`trig_range.xc`) that uses xtc-level range-bound
    // assertions (`if (a > X && a < Y)`) — that file covers sin,
    // cos, tan and the fpTrigReduce range-reduction paths. The
    // byte-exact short-circuit cases (sin/cos(0) = 0 exactly,
    // tan(±π/2) = ±inf) live in the "Infinity convention" block
    // further down and in trig_range.xc respectively.

}

void t_s11(void)
{
    // ── Float register-result convention ────────────────────────
    // These tests exercise the 5-byte float call/return path:
    //   (a) the callee leaves its result in $B0..$B4,
    //   (b) simple variable args still push correctly,
    //   (c) expression args are evaluated into $B0..$B4 and pushed,
    //   (d) nested float calls chain through the register slot.

    // (a) Plain float return: fadd(1.5, 2.5) -> 4.0
    { float g = fadd(1.5, 2.5);
      asm { LDA g : STA r0 : LDA g+1 : STA r1 : LDA g+2 : STA r2 : LDA g+3 : STA r3 : LDA g+4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $00; e3 = $00; e4 = $00; record(); }

    // (b) Variable args: fmul(a, b) where a=3.0, b=2.5 -> 7.5
    //     7.5 = 1.875 * 2^2 -> mantissa frac 0.875 * 2^24 = $E00000
    { float a = 3.0; float b = 2.5; float g = fmul(a, b);
      asm { LDA g : STA r0 : LDA g+1 : STA r1 : LDA g+2 : STA r2 : LDA g+3 : STA r3 : LDA g+4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $E0; e3 = $00; e4 = $00; record(); }

    // (c) Expression arg: fadd(a + b, c) with a=1.0, b=0.5, c=2.5 -> 4.0
    { float a = 1.0; float b = 0.5; float c = 2.5;
      float g = fadd(a + b, c);
      asm { LDA g : STA r0 : LDA g+1 : STA r1 : LDA g+2 : STA r2 : LDA g+3 : STA r3 : LDA g+4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $00; e3 = $00; e4 = $00; record(); }

    // (c') Both args are expressions: fmul(a + b, c + d)
    //     with a=1.0, b=0.5, c=0.5, d=0.5 -> 1.5 * 1.0 = 1.5
    //     1.5 = 1.5 * 2^0, frac 0.5*2^24 = $800000
    { float a = 1.0; float b = 0.5; float c = 0.5; float d = 0.5;
      float g = fmul(a + b, c + d);
      asm { LDA g : STA r0 : LDA g+1 : STA r1 : LDA g+2 : STA r2 : LDA g+3 : STA r3 : LDA g+4 : STA r4 }
      e0 = $00; e1 = $00; e2 = $80; e3 = $00; e4 = $00; record(); }

    // (d) Nested float calls: fadd(fdouble(1.5), 1.0)
    //     = fadd(3.0, 1.0) = 4.0
    { float g = fadd(fdouble(1.5), 1.0);
      asm { LDA g : STA r0 : LDA g+1 : STA r1 : LDA g+2 : STA r2 : LDA g+3 : STA r3 : LDA g+4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $00; e3 = $00; e4 = $00; record(); }

    // (d') Call result used in an expression arg:
    //      fmul(fdouble(1.5) + 1.0, 2.0) = fmul(4.0, 2.0) = 8.0
    //      8.0 = 1.0 * 2^3
    { float g = fmul(fdouble(1.5) + 1.0, 2.0);
      asm { LDA g : STA r0 : LDA g+1 : STA r1 : LDA g+2 : STA r2 : LDA g+3 : STA r3 : LDA g+4 : STA r4 }
      e0 = $00; e1 = $03; e2 = $00; e3 = $00; e4 = $00; record(); }

}

void t_s12(void)
{
    // ── Infinity convention ─────────────────────────────────────
    // flag bit 5 ($20) = infinity; sign bit 0 selects ± just like
    // for finite numbers. Only fpDiv (x/0 with x ≠ 0) and fpTan
    // (angle within ε of ±pi/2) emit ±inf. Everything else that sees
    // an infinity operand promotes the result to NaN ($08).

    // tan(pi/2) -> +inf
    { float a = 1.5707963;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            JSR fpTan
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $20; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // tan(−pi/2) -> −inf
    { float a = -1.5707963;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            JSR fpTan
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $21; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // −5 / 0 -> −inf
    { float a = -5.0; float b = 0.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpDiv
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $21; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // 5 / −0 -> −inf (sign of divisor contributes)
    { float a = 5.0; float b = -0.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpDiv
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $21; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // 0 / 0 -> NaN
    { float a = 0.0; float b = 0.0;
      asm { LDA a : STA $B0 : LDA a+1 : STA $B1 : LDA a+2 : STA $B2 : LDA a+3 : STA $B3 : LDA a+4 : STA $B4
            LDA b : STA $B5 : LDA b+1 : STA $B6 : LDA b+2 : STA $B7 : LDA b+3 : STA $B8 : LDA b+4 : STA $B9
            JSR fpDiv
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $08; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // (+inf) + 1 -> NaN. Construct +inf inline via 5/0, then feed it
    // to fpAdd as operand 1 with 1.0 as operand 2. No other route
    // short of a literal could produce an infinity operand today.
    { float one = 1.0; float five = 5.0; float zero = 0.0;
      asm { LDA five : STA $B0 : LDA five+1 : STA $B1 : LDA five+2 : STA $B2 : LDA five+3 : STA $B3 : LDA five+4 : STA $B4
            LDA zero : STA $B5 : LDA zero+1 : STA $B6 : LDA zero+2 : STA $B7 : LDA zero+3 : STA $B8 : LDA zero+4 : STA $B9
            JSR fpDiv              ; $B0-$B4 = +inf
            LDA one : STA $B5 : LDA one+1 : STA $B6 : LDA one+2 : STA $B7 : LDA one+3 : STA $B8 : LDA one+4 : STA $B9
            JSR fpAdd              ; inf + 1 -> NaN
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $08; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // (+inf) * 2 -> NaN via fpMul infinity guard.
    { float two = 2.0; float five = 5.0; float zero = 0.0;
      asm { LDA five : STA $B0 : LDA five+1 : STA $B1 : LDA five+2 : STA $B2 : LDA five+3 : STA $B3 : LDA five+4 : STA $B4
            LDA zero : STA $B5 : LDA zero+1 : STA $B6 : LDA zero+2 : STA $B7 : LDA zero+3 : STA $B8 : LDA zero+4 : STA $B9
            JSR fpDiv
            LDA two : STA $B5 : LDA two+1 : STA $B6 : LDA two+2 : STA $B7 : LDA two+3 : STA $B8 : LDA two+4 : STA $B9
            JSR fpMul
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $08; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // sqrt(+inf) -> NaN
    { float five = 5.0; float zero = 0.0;
      asm { LDA five : STA $B0 : LDA five+1 : STA $B1 : LDA five+2 : STA $B2 : LDA five+3 : STA $B3 : LDA five+4 : STA $B4
            LDA zero : STA $B5 : LDA zero+1 : STA $B6 : LDA zero+2 : STA $B7 : LDA zero+3 : STA $B8 : LDA zero+4 : STA $B9
            JSR fpDiv
            JSR fpSqrt
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $08; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // sin(+inf) -> NaN
    { float five = 5.0; float zero = 0.0;
      asm { LDA five : STA $B0 : LDA five+1 : STA $B1 : LDA five+2 : STA $B2 : LDA five+3 : STA $B3 : LDA five+4 : STA $B4
            LDA zero : STA $B5 : LDA zero+1 : STA $B6 : LDA zero+2 : STA $B7 : LDA zero+3 : STA $B8 : LDA zero+4 : STA $B9
            JSR fpDiv
            JSR fpSin
            LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3 : LDA $B4 : STA r4 }
      e0 = $08; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

}

void t_s13(void)
{
    // ── Float comparisons ───────────────────────────────────────
    // The if-body records a distinctive "pass" byte into r0 and
    // stuffs the rest of the record with zeros. The runner checks
    // byte-exact against the expected bytes the test sets; for a
    // comparison the expected is "$01 0 0 0 0" (condition true) or
    // "$00 0 0 0 0" (condition false). Each test exercises one
    // operator on a pair of float values with a known ordering.

    // 1.5 < 2.5  -> true
    { float a = 1.5; float b = 2.5; u8 flag = 0;
      if (a < b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $01; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 2.5 < 1.5  -> false
    { float a = 2.5; float b = 1.5; u8 flag = 0;
      if (a < b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $00; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 2.5 > 1.5  -> true
    { float a = 2.5; float b = 1.5; u8 flag = 0;
      if (a > b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $01; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 1.5 > 1.5  -> false (equal is not greater)
    { float a = 1.5; float b = 1.5; u8 flag = 0;
      if (a > b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $00; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 1.5 == 1.5 -> true
    { float a = 1.5; float b = 1.5; u8 flag = 0;
      if (a == b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $01; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 1.5 == 2.5 -> false
    { float a = 1.5; float b = 2.5; u8 flag = 0;
      if (a == b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $00; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 1.5 != 2.5 -> true
    { float a = 1.5; float b = 2.5; u8 flag = 0;
      if (a != b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $01; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 1.5 <= 1.5 -> true (equal path through <=)
    { float a = 1.5; float b = 1.5; u8 flag = 0;
      if (a <= b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $01; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 2.5 <= 1.5 -> false
    { float a = 2.5; float b = 1.5; u8 flag = 0;
      if (a <= b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $00; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 1.5 >= 1.5 -> true
    { float a = 1.5; float b = 1.5; u8 flag = 0;
      if (a >= b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $01; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // -3.0 < -1.0 -> true (negative magnitude flip)
    { float a = -3.0; float b = -1.0; u8 flag = 0;
      if (a < b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $01; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // -1.0 > -3.0 -> true
    { float a = -1.0; float b = -3.0; u8 flag = 0;
      if (a > b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $01; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // -0.5 < 0.5 -> true (different signs)
    { float a = -0.5; float b = 0.5; u8 flag = 0;
      if (a < b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $01; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 0.0 < 1.0 -> true (zero on the left)
    { float a = 0.0; float b = 1.0; u8 flag = 0;
      if (a < b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $01; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 0.0 == 0.0 -> true (both zero)
    { float a = 0.0; float b = 0.0; u8 flag = 0;
      if (a == b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $01; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // Expression operand on the left: (a + 1.0) == b where a=0.5, b=1.5
    { float a = 0.5; float b = 1.5; u8 flag = 0;
      if (a + 1.0 == b) flag = 1;
      r0 = flag; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $01; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

}

void t_s14(void)
{
    // ── Small-struct return ────────────────────────────────────
    // The 5-byte Five struct fits exactly in the record slot. The
    // expected row holds the same bytes the helper produced.

    // Declaration-init path: `Five v = make_five(10);`
    { Five v = make_five(10);
      r0 = v.a; r1 = v.b; r2 = v.c; r3 = v.d; r4 = v.e;
      e0 = 10;  e1 = 11;  e2 = 12;  e3 = 13;  e4 = 14;
      record(); }

    // Assignment path: `v = make_five(20);` after declaration.
    { Five v;
      v = make_five(20);
      r0 = v.a; r1 = v.b; r2 = v.c; r3 = v.d; r4 = v.e;
      e0 = 20;  e1 = 21;  e2 = 22;  e3 = 23;  e4 = 24;
      record(); }

    // Two calls in sequence — ensures nothing clobbers the second
    // call's return value before we copy it out.
    { Five a = make_five(1);
      Five b = make_five(100);
      r0 = b.a; r1 = b.b; r2 = b.c; r3 = b.d; r4 = b.e;
      e0 = 100; e1 = 101; e2 = 102; e3 = 103; e4 = 104;
      record(); }

}

void t_s15(void)
{
    // ── Large-struct return (12-byte Twelve via __retbuf) ─────
    // Byte 0..4 slice: verifies the declaration-init path pushes
    // &t as the hidden first arg and the callee writes through it.
    { Twelve t = make_twelve(50);
      r0 = t.v0; r1 = t.v1; r2 = t.v2; r3 = t.v3; r4 = t.v4;
      e0 = 50;   e1 = 51;   e2 = 52;   e3 = 53;   e4 = 54;
      record(); }

    // Byte 7..11 slice: makes sure the full struct made it — the
    // bug before the lowering pass was that bytes past the first
    // two were silently truncated.
    { Twelve t = make_twelve(200);
      r0 = t.v7; r1 = t.v8; r2 = t.v9; r3 = t.vA; r4 = t.vB;
      e0 = 207;  e1 = 208;  e2 = 209;  e3 = 210;  e4 = 211;
      record(); }

    // Two calls in sequence — no leftover __retbuf state.
    { Twelve a = make_twelve(1);
      Twelve b = make_twelve(10);
      r0 = b.v0; r1 = b.v3; r2 = b.v6; r3 = b.v9; r4 = b.vB;
      e0 = 10;   e1 = 13;   e2 = 16;   e3 = 19;   e4 = 21;
      record(); }

}

void t_s16(void)
{
    // ── Integer → float conversions ────────────────────────────
    // Runtime helpers in runtime/float/{u8,i8,u16,i16,u32,i32}ToFp
    // convert a narrow or wide integer variable to the 5-byte xtc
    // float format. Each test assigns a RUNTIME integer variable
    // (not a literal — those hit the compile-time fold path in
    // emitFloatTerminalTo and skip the runtime entirely) to a
    // local float and byte-compares the resulting float against
    // hand-computed expected bytes. Hand-computed values cross-
    // reference XTFloatEncoding.encodeDouble for the same value
    // as a double — if a conversion helper drifts, these tests
    // flag the exact mismatch.
    //
    // Format reminder: {flags, exp, mantissa_hi, mantissa_mid,
    // mantissa_lo}. exp is signed int8. mantissa has an implicit
    // leading 1 stripped.

    // u8: 0 (zero-flag path).
    { u8 x = 0; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // u8: 1 = 1.0 * 2^0, mantissa 0.
    { u8 x = 1; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $00; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // u8: 200 = 1.5625 * 2^7, frac = 0.5625 → mantissa $90,$00,$00.
    { u8 x = 200; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $00; e1 = $07; e2 = $90; e3 = $00; e4 = $00; record(); }

    // i8: -1 = -1.0 → sign bit + mantissa 0.
    { i8 x = -1; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $01; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // i8: -128 = -(1.0 * 2^7) → sign + exp=7 + mantissa 0.
    { i8 x = -128; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $01; e1 = $07; e2 = $00; e3 = $00; e4 = $00; record(); }

    // u16: 1000 = 1.953125 * 2^9, frac = 0.953125 → mantissa $F4.
    { u16 x = 1000; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $00; e1 = $09; e2 = $F4; e3 = $00; e4 = $00; record(); }

    // u16: 65535 = (1 + 32767/32768) * 2^15 → mantissa = 32767 * 2
    // = 65534 = $FFFE00.
    { u16 x = $FFFF; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $00; e1 = $0F; e2 = $FF; e3 = $FE; e4 = $00; record(); }

    // i16: -1000 = -(1.953125 * 2^9) → sign + $09,$F4,$00,$00.
    { i16 x = -1000; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $01; e1 = $09; e2 = $F4; e3 = $00; e4 = $00; record(); }

    // i16: -32768 = -(1.0 * 2^15) → sign + exp=15 + mantissa 0.
    { i16 x = -32768; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $01; e1 = $0F; e2 = $00; e3 = $00; e4 = $00; record(); }

    // u32: 0 → zero-flag.
    { u32 x = 0; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $10; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // u32: 1000000 = 1.9073... * 2^19. MSB at bit 19, shifts=12.
    // Drop-1 shift leaves mantissa $E8,$48,$00 in the top 24 bits.
    { u32 x = 1000000; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $00; e1 = $13; e2 = $E8; e3 = $48; e4 = $00; record(); }

    // u32: 16777216 = 2^24 exactly → exp=24, mantissa 0.
    { u32 x = 16777216; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $00; e1 = $18; e2 = $00; e3 = $00; e4 = $00; record(); }

    // u32: 16777215 = 2^24 - 1. Largest value exactly representable
    // without precision loss. MSB at bit 23, shifts=8, then drop-1
    // leaves mantissa $FF,$FF,$FE.
    { u32 x = 16777215; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $00; e1 = $17; e2 = $FF; e3 = $FF; e4 = $FE; record(); }

    // i32: -1 → sign + 1.0.
    { i32 x = -1; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $01; e1 = $00; e2 = $00; e3 = $00; e4 = $00; record(); }

    // i32: -2147483647 = -(2^31 - 1). MSB at bit 30. The
    // 24-bit mantissa can't represent all 30 non-MSB bits so the
    // low 6 bits are truncated — mantissa = $FF,$FF,$FF.
    { i32 x = -2147483647; float f = x;
      asm { LDA f   : STA r0
            LDA f+1 : STA r1
            LDA f+2 : STA r2
            LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      e0 = $01; e1 = $1E; e2 = $FF; e3 = $FF; e4 = $FF; record(); }

}

void t_s17(void)
{
    // ── Float compound assignments ─────────────────────────────
    // `r += f`, `r -= f`, `r *= f`, `r /= f` for float-typed r
    // used to fall through to the integer in-place compound path
    // (which only knows how to ADC/SBC u8 and AND/ORA/EOR u16),
    // emitting a CLC / LDA r / ADC <byte> / STA r sequence over
    // the float's first two bytes and corrupting the float into
    // garbage that fp2Asc rendered as -inf or 0.0. Fixed by
    // letting the desugar path (a OP= b → a = a OP b) handle
    // float LHS too — the synthesised `a = a OP b` then routes
    // through the float branch of emitAssignExpr, which calls
    // fpAdd/fpSub/fpMul/fpDiv via emitFloatExprToB0. Each test
    // captures the post-op float bytes and compares against the
    // hand-computed expected encoding.

    // r += f: 6.0 + 3.0 = 9.0 = 1.125 * 2^3 → mantissa $20,$00,$00
    { float r = 6.0; float k = 3.0;
      r += k;
      asm { LDA r   : STA r0
            LDA r+1 : STA r1
            LDA r+2 : STA r2
            LDA r+3 : STA r3
            LDA r+4 : STA r4 }
      e0 = $00; e1 = $03; e2 = $20; e3 = $00; e4 = $00; record(); }

    // r -= f: 5.0 - 2.0 = 3.0 = 1.5 * 2^1 → mantissa $80,$00,$00
    { float r = 5.0; float k = 2.0;
      r -= k;
      asm { LDA r   : STA r0
            LDA r+1 : STA r1
            LDA r+2 : STA r2
            LDA r+3 : STA r3
            LDA r+4 : STA r4 }
      e0 = $00; e1 = $01; e2 = $80; e3 = $00; e4 = $00; record(); }

    // r *= f: 2.5 * 4.0 = 10.0 = 1.25 * 2^3 → mantissa $40,$00,$00
    { float r = 2.5; float k = 4.0;
      r *= k;
      asm { LDA r   : STA r0
            LDA r+1 : STA r1
            LDA r+2 : STA r2
            LDA r+3 : STA r3
            LDA r+4 : STA r4 }
      e0 = $00; e1 = $03; e2 = $40; e3 = $00; e4 = $00; record(); }

    // r /= f: 8.0 / 2.0 = 4.0 = 1.0 * 2^2 → mantissa $00,$00,$00
    { float r = 8.0; float k = 2.0;
      r /= k;
      asm { LDA r   : STA r0
            LDA r+1 : STA r1
            LDA r+2 : STA r2
            LDA r+3 : STA r3
            LDA r+4 : STA r4 }
      e0 = $00; e1 = $02; e2 = $00; e3 = $00; e4 = $00; record(); }

    // r += <int literal converted to float>: exercises the
    // emitFloatTerminalTo int-literal-to-float fast path on the
    // RHS of a desugared compound assign. 4.0 + 7 = 11.0 =
    // 1.375 * 2^3 → mantissa $60,$00,$00. The int literal 7
    // gets encoded as a float at compile time and added via
    // fpAdd. Without the desugar fix, this would fall through
    // to the integer compound-assign path and corrupt r.
    { float r = 4.0;
      r += 7;
      asm { LDA r   : STA r0
            LDA r+1 : STA r1
            LDA r+2 : STA r2
            LDA r+3 : STA r3
            LDA r+4 : STA r4 }
      e0 = $00; e1 = $03; e2 = $60; e3 = $00; e4 = $00; record(); }

}

void t_s18(void)
{
    // ── -O3 register-tracker regression ───────────────────────
    // `lval = $deadbeef; hi = (lval >> 16) & $ffff;` used to
    // miscompile to $BEAD at -O2+ because the optimiser elided an
    // LDX reload before an STX to the same address, thinking X
    // already held that memory — but the memory had been
    // overwritten by an intervening STA. This test captures the
    // high u16 of $deadbeef and records its bytes. Expected:
    // lo=$AD, hi=$DE (i.e. $DEAD).
    { u32 lval = $deadbeef;
      u16 hi   = (lval >> 16) & $ffff;
      u16 lo   = lval         & $ffff;
      r0 = hi & $ff;   r1 = (hi >> 8) & $ff;
      r2 = lo & $ff;   r3 = (lo >> 8) & $ff;
      r4 = 0;
      e0 = $AD; e1 = $DE;
      e2 = $EF; e3 = $BE;
      e4 = 0;
      record(); }

}

void main(void)
{
    testCount = 0;
    failCount = 0;

    t_s1();
    t_s2();
    t_s3();
    t_s4();
    t_s5();
    t_s6();
    t_s7();
    t_s8();
    t_s9();
    t_s10();
    t_s11();
    t_s12();
    t_s13();
    t_s14();
    t_s15();
    t_s16();
    t_s17();
    t_s18();

    // Flush any captured failure test numbers before the DONE line
    // so the harness can see which specific tests mismatched.
    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}
