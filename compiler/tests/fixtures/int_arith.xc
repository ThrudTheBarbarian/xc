// int_arith.xc — regression test for integer arithmetic and
// comparison across the six built-in integer types: u8, i8, u16,
// i16, u32, i32.
//
// Each test block computes a value via ordinary xtc expression
// syntax, copies the result bytes into r0..r4, writes the
// expected bytes into e0..e4, and calls record() to compare
// them byte-wise and emit "T<n> FAIL" via Stdio.printf on mismatch.
// A correct run prints only the "DONE 108" terminator (see the
// .expected.out oracle).
//
// Scope:
//   * Arithmetic: + - * / %      * Bitwise: & | ^ ~
//   * Compare:    < > <= >= == != * Shift:   << >>
//   * Compound assignment, unary, cross-width widening.
//
// The body is split into one function per section. A single 100+-block
// main() overflows the xt6502 unbanked code budget (~22 KB) and can't be
// bank-split (banking is function-granularity), so each section is its own
// function — small enough to stay unbanked or be packed into a code bank.
//
// xt6502-only: result bytes for the wide types are extracted with 6502
// inline asm, which the arm64 reference backend can't execute.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — dereferences the 6502 zero-page ($0000) sentinel

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

u8 testCount;

// record() is called silently on pass — only mismatches print a line.
void record(void)
{
    testCount = testCount + 1;
    if (r0 != e0 || r1 != e1 || r2 != e2 || r3 != e3 || r4 != e4) {
        Stdio.printf("T%u FAIL\n", testCount);
    }
}

// ══════════════════════════════════════════════════════════════════
// u8 arithmetic
// ══════════════════════════════════════════════════════════════════
void t_u8_arith(void)
{
    { u8 a = 30; u8 b = 12; u8 c = a + b;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 42; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u8 a = 100; u8 b = 77; u8 c = a - b;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 23; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // u8 overflow: 200 + 100 = 300 wraps to 44.
    { u8 a = 200; u8 b = 100; u8 c = a + b;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 44; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u8 a = 12; u8 b = 7; u8 c = a * b;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 84; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u8 a = 200; u8 b = 13; u8 c = a / b;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 15; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u8 a = 200; u8 b = 13; u8 c = a % b;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 5; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
}

// ══════════════════════════════════════════════════════════════════
// i8 arithmetic
// ══════════════════════════════════════════════════════════════════
void t_i8_arith(void)
{
    // -20 + 50 = 30. $EC + $32 = $11E → $1E = 30. Sign OK.
    { i8 a = -20; i8 b = 50; i8 c = a + b;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 30; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 20 - 50 = -30 = $E2 as i8.
    { i8 a = 20; i8 b = 50; i8 c = a - b;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $E2; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // -6 * 7 = -42 = $D6 as i8.
    { i8 a = -6; i8 b = 7; i8 c = a * b;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $D6; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // -42 / 6 = -7 = $F9 as i8.
    { i8 a = -42; i8 b = 6; i8 c = a / b;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $F9; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // -17 % 5 — C99 semantics: result takes sign of dividend, -2 = $FE.
    { i8 a = -17; i8 b = 5; i8 c = a % b;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $FE; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
}

// ══════════════════════════════════════════════════════════════════
// u16 arithmetic
// ══════════════════════════════════════════════════════════════════
void t_u16_arith(void)
{
    // 1000 + 2345 = 3345 = $0D11
    { u16 a = 1000; u16 b = 2345; u16 c = a + b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $11; e1 = $0D; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 60000 - 1234 = 58766 = $E58E
    { u16 a = 60000; u16 b = 1234; u16 c = a - b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $8E; e1 = $E5; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 300 * 200 = 60000 = $EA60
    { u16 a = 300; u16 b = 200; u16 c = a * b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $60; e1 = $EA; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 50000 / 123 = 406 = $0196
    { u16 a = 50000; u16 b = 123; u16 c = a / b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $96; e1 = $01; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 50000 % 123 = 62 = $003E
    { u16 a = 50000; u16 b = 123; u16 c = a % b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = 62; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
}

// ══════════════════════════════════════════════════════════════════
// i16 arithmetic
// ══════════════════════════════════════════════════════════════════
void t_i16_arith(void)
{
    // -5000 + 12000 = 7000 = $1B58
    { i16 a = -5000; i16 b = 12000; i16 c = a + b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $58; e1 = $1B; e2 = 0; e3 = 0; e4 = 0; record(); }

    // 5000 - 12000 = -7000 = $E4A8 (two's comp)
    { i16 a = 5000; i16 b = 12000; i16 c = a - b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $A8; e1 = $E4; e2 = 0; e3 = 0; e4 = 0; record(); }

    // -123 * 100 = -12300 = $CFF4
    { i16 a = -123; i16 b = 100; i16 c = a * b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $F4; e1 = $CF; e2 = 0; e3 = 0; e4 = 0; record(); }

    // -12300 / 100 = -123 = $FF85
    { i16 a = -12300; i16 b = 100; i16 c = a / b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $85; e1 = $FF; e2 = 0; e3 = 0; e4 = 0; record(); }

    // -17 % 5 = -2 = $FFFE
    { i16 a = -17; i16 b = 5; i16 c = a % b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $FE; e1 = $FF; e2 = 0; e3 = 0; e4 = 0; record(); }
}

// ══════════════════════════════════════════════════════════════════
// u32 arithmetic
// ══════════════════════════════════════════════════════════════════
void t_u32_arith(void)
{
    // 100000 + 234567 = 334567 = $00051AE7
    { u32 a = 100000; u32 b = 234567; u32 c = a + b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $E7; e1 = $1A; e2 = $05; e3 = $00; e4 = 0; record(); }

    // $DEADBEEF - $01000000 = $DDADBEEF
    { u32 a = $deadbeef; u32 b = $01000000; u32 c = a - b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $EF; e1 = $BE; e2 = $AD; e3 = $DD; e4 = 0; record(); }

    // 65537 * 100 = 6553700 = $00640064
    { u32 a = 65537; u32 b = 100; u32 c = a * b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $64; e1 = $00; e2 = $64; e3 = $00; e4 = 0; record(); }

    // 1000000 / 1234 = 810 = $0000032A
    { u32 a = 1000000; u32 b = 1234; u32 c = a / b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $2A; e1 = $03; e2 = $00; e3 = $00; e4 = 0; record(); }

    // 1000000 % 1234 = 460 = $000001CC
    { u32 a = 1000000; u32 b = 1234; u32 c = a % b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $CC; e1 = $01; e2 = $00; e3 = $00; e4 = 0; record(); }
}

// ══════════════════════════════════════════════════════════════════
// i32 arithmetic
// ══════════════════════════════════════════════════════════════════
void t_i32_arith(void)
{
    // -100000 + 250000 = 150000 = $000249F0
    { i32 a = -100000; i32 b = 250000; i32 c = a + b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $F0; e1 = $49; e2 = $02; e3 = $00; e4 = 0; record(); }

    // 100000 - 250000 = -150000 = $FFFDB610
    { i32 a = 100000; i32 b = 250000; i32 c = a - b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $10; e1 = $B6; e2 = $FD; e3 = $FF; e4 = 0; record(); }

    // -123 * 1000 = -123000 = $FFFE1F88
    { i32 a = -123; i32 b = 1000; i32 c = a * b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $88; e1 = $1F; e2 = $FE; e3 = $FF; e4 = 0; record(); }

    // -1000000 / 7 = -142857 = $FFFDD1F7 (C99 trunc-toward-zero)
    { i32 a = -1000000; i32 b = 7; i32 c = a / b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $F7; e1 = $D1; e2 = $FD; e3 = $FF; e4 = 0; record(); }

    // -1000000 % 7 = -1 = $FFFFFFFF
    { i32 a = -1000000; i32 b = 7; i32 c = a % b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $FF; e1 = $FF; e2 = $FF; e3 = $FF; e4 = 0; record(); }
}

// ══════════════════════════════════════════════════════════════════
// Compare operators — one TRUE and one FALSE case per operator/type.
// ══════════════════════════════════════════════════════════════════
void t_compares(void)
{
    // ── u8 compares ──
    { u8 a = 10; u8 b = 20; u8 f = 0; if (a < b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u8 a = 20; u8 b = 10; u8 f = 0; if (a < b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 0; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u8 a = 20; u8 b = 10; u8 f = 0; if (a > b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u8 a = 10; u8 b = 10; u8 f = 0; if (a <= b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u8 a = 10; u8 b = 10; u8 f = 0; if (a >= b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u8 a = 10; u8 b = 10; u8 f = 0; if (a == b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u8 a = 10; u8 b = 11; u8 f = 0; if (a != b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── i8 compares (signed) ──
    { i8 a = -5; i8 b = 3; u8 f = 0; if (a < b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { i8 a = 3; i8 b = -5; u8 f = 0; if (a > b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { i8 a = -5; i8 b = -5; u8 f = 0; if (a == b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── u16 compares ──
    { u16 a = 1000; u16 b = 2000; u8 f = 0; if (a < b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u16 a = 50000; u16 b = 40000; u8 f = 0; if (a < b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 0; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u16 a = 1234; u16 b = 1234; u8 f = 0; if (a == b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── i16 compares ──
    { i16 a = -1000; i16 b = 1000; u8 f = 0; if (a < b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { i16 a = 1000; i16 b = -1000; u8 f = 0; if (a > b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── u32 compares (the 4-byte compare regression) ──
    { u32 a = 1000; u32 b = 1000000; u8 f = 0; if (a < b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u32 a = 1000000; u32 b = 1000; u8 f = 0; if (a < b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 0; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u32 a = 1000000; u32 b = 1000000; u8 f = 0; if (a == b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u32 a = 1000000; u32 b = 1000001; u8 f = 0; if (a != b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── i32 compares ──
    { i32 a = -1000000; i32 b = 1000000; u8 f = 0; if (a < b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { i32 a = 1000000; i32 b = -1000000; u8 f = 0; if (a > b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
}

// ══════════════════════════════════════════════════════════════════
// Cross-width: mixed-width arithmetic widens to the wider operand
// (spec §3.1: `u8 + u16` → `u16`). Same-width `u8 + u8` stays u8 and
// would wrap to 44 — this case mixes widths so the sum is the true 300.
// ══════════════════════════════════════════════════════════════════
void t_crosswidth(void)
{
    // 200 + 100 overflows a u8 but fits the u16 the add widens to: 300.
    { u8 a = 200; u16 b = 100; u16 c;
      c = a + b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $2C; e1 = $01; e2 = 0; e3 = 0; e4 = 0; record(); }
}

// ══════════════════════════════════════════════════════════════════
// Bitwise operators — & | ^ ~
// ══════════════════════════════════════════════════════════════════
void t_bitwise(void)
{
    // ── u8 bitwise ──
    { u8 a = $F0; u8 b = $AA; u8 c = a & b;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $A0; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u8 a = $F0; u8 b = $0F; u8 c = a | b;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $FF; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u8 a = $FF; u8 b = $AA; u8 c = a ^ b;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $55; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u8 a = $55; u8 c = ~a;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $AA; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── u16 bitwise ──
    { u16 a = $FF00; u16 b = $0FF0; u16 c = a & b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $00; e1 = $0F; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u16 a = $FF00; u16 b = $00FF; u16 c = a | b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $FF; e1 = $FF; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u16 a = $FFFF; u16 b = $AA55; u16 c = a ^ b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $AA; e1 = $55; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── u32 bitwise ──
    { u32 a = $FF00FF00; u32 b = $0FF00FF0; u32 c = a & b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $00; e1 = $0F; e2 = $00; e3 = $0F; e4 = 0; record(); }

    { u32 a = $FF000000; u32 b = $000000FF; u32 c = a | b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $FF; e1 = $00; e2 = $00; e3 = $FF; e4 = 0; record(); }

    { u32 a = $FFFFFFFF; u32 b = $AA55AA55; u32 c = a ^ b;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $AA; e1 = $55; e2 = $AA; e3 = $55; e4 = 0; record(); }
}

// ══════════════════════════════════════════════════════════════════
// Shift operators — << >>
// ══════════════════════════════════════════════════════════════════
void t_shifts(void)
{
    // ── u8 shifts ──
    { u8 a = $05; u8 c = a << 3;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $28; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u8 a = $80; u8 c = a >> 3;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $10; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── i8 arithmetic shift right: sign bit must propagate ──
    { i8 a = -16; i8 c = a >> 2;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $FC; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── u16 shifts ──
    { u16 a = $00FF; u16 c = a << 4;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $F0; e1 = $0F; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u16 a = $F000; u16 c = a >> 4;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $00; e1 = $0F; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── i16 arithmetic shift right ──
    { i16 a = -1024; i16 c = a >> 4;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $C0; e1 = $FF; e2 = 0; e3 = 0; e4 = 0; record(); }

    // ── u32 shifts ──
    { u32 a = $000000FF; u32 c = a << 16;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $00; e1 = $00; e2 = $FF; e3 = $00; e4 = 0; record(); }

    { u32 a = $DEADBEEF; u32 c = a >> 16;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $AD; e1 = $DE; e2 = $00; e3 = $00; e4 = 0; record(); }

    // ── i32 arithmetic shift right: -65536 >> 8 = -256 = $FFFFFF00 ──
    { i32 a = -65536; i32 c = a >> 8;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $00; e1 = $FF; e2 = $FF; e3 = $FF; e4 = 0; record(); }
}

// ══════════════════════════════════════════════════════════════════
// Additional compare coverage — <= >= != for signed and wide
// ══════════════════════════════════════════════════════════════════
void t_more_compares(void)
{
    { i8 a = -5; i8 b = 3; u8 f = 0; if (a <= b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { i8 a = 3; i8 b = -5; u8 f = 0; if (a >= b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { i8 a = -5; i8 b = 3; u8 f = 0; if (a != b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u16 a = 1234; u16 b = 1234; u8 f = 0; if (a <= b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u16 a = 50000; u16 b = 40000; u8 f = 0; if (a >= b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u16 a = 1234; u16 b = 5678; u8 f = 0; if (a != b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    { i16 a = -1000; i16 b = -1000; u8 f = 0; if (a <= b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { i16 a = -1000; i16 b = -2000; u8 f = 0; if (a >= b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { i16 a = -1000; i16 b = -1000; u8 f = 0; if (a == b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { i16 a = -1000; i16 b = 1000; u8 f = 0; if (a != b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u32 a = 1000000; u32 b = 1000000; u8 f = 0; if (a <= b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u32 a = 1000000; u32 b = 1000; u8 f = 0; if (a >= b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u32 a = 1000000; u32 b = 1000; u8 f = 0; if (a > b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    { i32 a = -1000000; i32 b = -1000000; u8 f = 0; if (a <= b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { i32 a = -1000000; i32 b = -2000000; u8 f = 0; if (a >= b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { i32 a = -1000000; i32 b = -1000000; u8 f = 0; if (a == b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { i32 a = -1000000; i32 b = 1000000; u8 f = 0; if (a != b) f = 1;
      r0 = f; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
}

// ══════════════════════════════════════════════════════════════════
// Compound assignment: += -= *= /= %= &= |= ^= <<= >>=
// ══════════════════════════════════════════════════════════════════
void t_compound(void)
{
    { u8 a = 30; a += 12;
      r0 = a; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 42; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u8 a = 100; a -= 77;
      r0 = a; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 23; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // i8 -6 *= 7 → -42 = $D6
    { i8 a = -6; a *= 7;
      r0 = a; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $D6; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // i16 -12300 /= 100 → -123 = $FF85
    { i16 a = -12300; a /= 100;
      asm { LDA a : STA r0 : LDA a+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $85; e1 = $FF; e2 = 0; e3 = 0; e4 = 0; record(); }

    // i32 -1000000 %= 7 → -1 = $FFFFFFFF
    { i32 a = -1000000; a %= 7;
      asm { LDA a : STA r0 : LDA a+1 : STA r1 : LDA a+2 : STA r2 : LDA a+3 : STA r3 }
      r4 = 0;
      e0 = $FF; e1 = $FF; e2 = $FF; e3 = $FF; e4 = 0; record(); }

    { u8 a = $F0; a &= $AA;
      r0 = a; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $A0; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u16 a = $FF00; a |= $00FF;
      asm { LDA a : STA r0 : LDA a+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $FF; e1 = $FF; e2 = 0; e3 = 0; e4 = 0; record(); }

    { u32 a = $FFFFFFFF; a ^= $AA55AA55;
      asm { LDA a : STA r0 : LDA a+1 : STA r1 : LDA a+2 : STA r2 : LDA a+3 : STA r3 }
      r4 = 0;
      e0 = $AA; e1 = $55; e2 = $AA; e3 = $55; e4 = 0; record(); }

    { u8 a = $05; a <<= 3;
      r0 = a; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = $28; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // i16 -1024 >>= 4 → -64 = $FFC0
    { i16 a = -1024; a >>= 4;
      asm { LDA a : STA r0 : LDA a+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $C0; e1 = $FF; e2 = 0; e3 = 0; e4 = 0; record(); }
}

// ══════════════════════════════════════════════════════════════════
// Unary operators: - ~ ! prefix-++/-- postfix-++/--
// ══════════════════════════════════════════════════════════════════
void t_unary(void)
{
    // i8 negate: -(−7) = 7
    { i8 a = -7; i8 c = -a;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 7; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // i16 negate: -(1234) = -1234 = $FB2E
    { i16 a = 1234; i16 c = -a;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $2E; e1 = $FB; e2 = 0; e3 = 0; e4 = 0; record(); }

    // i32 negate: -(1000000) = -1000000 = $FFF0BDC0
    { i32 a = 1000000; i32 c = -a;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r4 = 0;
      e0 = $C0; e1 = $BD; e2 = $F0; e3 = $FF; e4 = 0; record(); }

    // Logical not: !0 = 1, !5 = 0
    { u8 a = 0; u8 c = !a;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u8 a = 5; u8 c = !a;
      r0 = c; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 0; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // Prefix ++/--
    { u8 a = 10; ++a;
      r0 = a; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 11; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u8 a = 10; --a;
      r0 = a; r1 = 0; r2 = 0; r3 = 0; r4 = 0;
      e0 = 9; e1 = 0; e2 = 0; e3 = 0; e4 = 0; record(); }

    // Postfix ++/-- on u16 to exercise wide inc/dec
    { u16 a = $00FF; a++;
      asm { LDA a : STA r0 : LDA a+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $00; e1 = $01; e2 = 0; e3 = 0; e4 = 0; record(); }
    { u16 a = $0100; a--;
      asm { LDA a : STA r0 : LDA a+1 : STA r1 }
      r2 = 0; r3 = 0; r4 = 0;
      e0 = $FF; e1 = $00; e2 = 0; e3 = 0; e4 = 0; record(); }
}

void main(void)
{
    testCount = 0;

    t_u8_arith();
    t_i8_arith();
    t_u16_arith();
    t_i16_arith();
    t_u32_arith();
    t_i32_arith();
    t_compares();
    t_crosswidth();
    t_bitwise();
    t_shifts();
    t_more_compares();
    t_compound();
    t_unary();

    Stdio.printf("DONE %u\n", testCount);
}
