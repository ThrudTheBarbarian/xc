//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
//xtc-flags: skip  — asserts retired 5-byte softfloat byte layout / large-float edge; needs IEEE-format rewrite (MECH migration, phase-671)
// printFloat's `STA (self),Y` plumbing (phase-171: arm64 backend now
// assembles inline asm verbatim).
// printf_float.xc — regression test for Stdio.printf %f on every
// memory model. Catches the inline-asm self-pointer hardcoding bug
// in lib/Stdio.xc's printFloat method, where `STA ($8A),Y` worked on
// xl by coincidence (xl's self pointer happens to land at $8A) but
// silently corrupted the xtc stack on xt and xe (their self pointer
// lives at $91 because $89/$8A is the stack pointer pair on the
// banked targets), leaving the fpBufPtr ivar unset and every %f
// producing empty output.
//
// The fixture prints `1.500000` at the top-left of the screen via
// Stdio.printf %f, then reads the first three screen RAM bytes back
// through Stdio's screenBase ivar (offset 2 in __sdata_Stdio) and
// compares them against the Atari screen codes for '1', '.', '5'
// ($11, $0E, $15). On the broken state the screen bytes are still
// blank ($00) and the test reports T1..T3 FAIL.
//
// Three more tests print 2.5, 3.5 and 4.5 from local floats so the
// same code path is exercised across multiple printf calls in the
// same `main` (the original bug repro needed two locals — a single
// local hid the issue because the format string happened to land
// at a position that didn't expose the corruption).

#import "Stdio.xc"

u8 r0;
u8 r1;
u8 r2;

u8 e0;
u8 e1;
u8 e2;

u8 testCount;
u8 failCount;
u8 fails[16];

void record(void)
{
    testCount = testCount + 1;
    if (r0 != e0 || r1 != e1 || r2 != e2) {
        if (failCount < 16) { fails[failCount] = testCount; }
        failCount = failCount + 1;
    }
}

void main(void)
{
    testCount = 0;
    failCount = 0;

    // ── T1: literal float via printf %f ────────────────────────
    // Print "1.5..." at (0,0), then read screen[0..2].
    // Expected screen codes: '1'=$11, '.'=$0E, '5'=$15.
    Stdio.setCursor(0, 0);
    Stdio.printf("%f", 1.5);
    asm {
        LDA __sdata_Stdio + _ivar_Stdio_screenBase : STA $86
        LDA __sdata_Stdio + _ivar_Stdio_screenBase+1 : STA $87
        LDY #$00 : LDA ($86),Y : STA r0
        LDY #$01 : LDA ($86),Y : STA r1
        LDY #$02 : LDA ($86),Y : STA r2
    }
    e0 = $11; e1 = $0E; e2 = $15; record();

    // ── T2: float local via printf %f ──────────────────────────
    Stdio.setCursor(0, 1);
    { float a = 2.5;
      Stdio.printf("%f", a); }
    asm {
        LDA __sdata_Stdio + _ivar_Stdio_screenBase : STA $86
        LDA __sdata_Stdio + _ivar_Stdio_screenBase+1 : STA $87
        LDA #40 : CLC : ADC $86 : STA $86
        LDA #00 : ADC $87 : STA $87
        LDY #$00 : LDA ($86),Y : STA r0
        LDY #$01 : LDA ($86),Y : STA r1
        LDY #$02 : LDA ($86),Y : STA r2
    }
    e0 = $12; e1 = $0E; e2 = $15; record();

    // ── T3 / T4: two float locals printed in one call ──────────
    // This is the multi-local repro that exposed the original bug.
    Stdio.setCursor(0, 2);
    { float a = 3.5; float b = 4.5;
      Stdio.printf("%f %f", a, b); }
    // Read the start of each float on the screen line. "3.5..."
    // begins at column 0; the gap " " is at column 8; "4.5..."
    // begins at column 9. Screen base + 80 puts us on row 2.
    asm {
        LDA __sdata_Stdio + _ivar_Stdio_screenBase : STA $86
        LDA __sdata_Stdio + _ivar_Stdio_screenBase+1 : STA $87
        LDA #80 : CLC : ADC $86 : STA $86
        LDA #00 : ADC $87 : STA $87
        LDY #$00 : LDA ($86),Y : STA r0
        LDY #$01 : LDA ($86),Y : STA r1
        LDY #$02 : LDA ($86),Y : STA r2
    }
    e0 = $13; e1 = $0E; e2 = $15; record();

    asm {
        LDA __sdata_Stdio + _ivar_Stdio_screenBase : STA $86
        LDA __sdata_Stdio + _ivar_Stdio_screenBase+1 : STA $87
        LDA #80 : CLC : ADC $86 : STA $86
        LDA #00 : ADC $87 : STA $87
        LDY #$09 : LDA ($86),Y : STA r0
        LDY #$0A : LDA ($86),Y : STA r1
        LDY #$0B : LDA ($86),Y : STA r2
    }
    e0 = $14; e1 = $0E; e2 = $15; record();

    // ── T5: large float beyond the old fp2Asc inf ceiling ─────
    // 4294967168.0 is the closest 24-bit-mantissa float to
    // $FFFFFFFF — exp = $1F = 31, which the old fp2Asc rejected
    // outright with `inf`. Verify the first three screen codes
    // are '4', '2', '9' = $14, $12, $19.
    Stdio.setCursor(0, 3);
    Stdio.printf("%f", 4294967168.0);
    asm {
        LDA __sdata_Stdio + _ivar_Stdio_screenBase : STA $86
        LDA __sdata_Stdio + _ivar_Stdio_screenBase+1 : STA $87
        LDA #120 : CLC : ADC $86 : STA $86
        LDA #00  : ADC $87 : STA $87
        LDY #$00 : LDA ($86),Y : STA r0
        LDY #$01 : LDA ($86),Y : STA r1
        LDY #$02 : LDA ($86),Y : STA r2
    }
    e0 = $14; e1 = $12; e2 = $19; record();

    // ── T6: negative float literal as printf arg ──────────────
    // The printf vararg packer used to flip bit 7 ($80) when
    // negating a literal float, but the format's sign bit is
    // bit 0 ($01). The bug ate the minus sign on every direct
    // negative literal: `printf("%f", -100.0)` came out as
    // "100.000000". This tests the cell at column 0 of row 4
    // contains the Atari screen code for '-' = $1C.
    Stdio.setCursor(0, 4);
    Stdio.printf("%f", -100.0);
    asm {
        LDA __sdata_Stdio + _ivar_Stdio_screenBase : STA $86
        LDA __sdata_Stdio + _ivar_Stdio_screenBase+1 : STA $87
        LDA #160 : CLC : ADC $86 : STA $86
        LDA #00  : ADC $87 : STA $87
        LDY #$00 : LDA ($86),Y : STA r0
        LDY #$01 : LDA ($86),Y : STA r1
        LDY #$02 : LDA ($86),Y : STA r2
    }
    e0 = $0D; e1 = $11; e2 = $10; record();    // '-', '1', '0'

    // ── T7: negative-exponent float (0 < val < 1) ─────────────
    // fp2Asc's neg_exp path had an off-by-one in the shift count:
    // it computed `V << (7 + exp)` when the correct formula is
    // `V << (8 + exp)` — exactly half the true value. Every
    // printf %f of a sub-1.0 float came out as half: 0.5 → "0.25",
    // 0.25 → "0.125", etc. Not caught by float_arith.xc because
    // that fixture compares raw float bytes via asm, not printed
    // output. Row 5, first three screen codes for "0.5" = '0',
    // '.', '5' = $10, $0E, $15.
    Stdio.setCursor(0, 5);
    Stdio.printf("%f", 0.5);
    asm {
        LDA __sdata_Stdio + _ivar_Stdio_screenBase : STA $86
        LDA __sdata_Stdio + _ivar_Stdio_screenBase+1 : STA $87
        LDA #200 : CLC : ADC $86 : STA $86
        LDA #00  : ADC $87 : STA $87
        LDY #$00 : LDA ($86),Y : STA r0
        LDY #$01 : LDA ($86),Y : STA r1
        LDY #$02 : LDA ($86),Y : STA r2
    }
    e0 = $10; e1 = $0E; e2 = $15; record();    // '0', '.', '5'

    // ── T8: literal 1.0 through printf %f ─────────────────────
    // 1.0 is encoded as {$00, $00, $00, $00, $00} — same bytes as
    // the all-zeros sentinel fp2Asc used to fall back on for
    // "0.0" output. The old "all-mantissa-bytes-zero → print 0.0"
    // shortcut confused 1.0 for 0.0 and every `printf("%f", 1.0)`
    // came out as "0.0". Fixed by checking the zero flag (bit 4
    // of the flags byte) properly and letting 1.0 go through
    // normal processing. Row 6, first three screen codes for
    // "1.0" = '1', '.', '0' = $11, $0E, $10.
    Stdio.setCursor(0, 6);
    Stdio.printf("%f", 1.0);
    asm {
        LDA __sdata_Stdio + _ivar_Stdio_screenBase : STA $86
        LDA __sdata_Stdio + _ivar_Stdio_screenBase+1 : STA $87
        LDA #240 : CLC : ADC $86 : STA $86
        LDA #00  : ADC $87 : STA $87
        LDY #$00 : LDA ($86),Y : STA r0
        LDY #$01 : LDA ($86),Y : STA r1
        LDY #$02 : LDA ($86),Y : STA r2
    }
    e0 = $11; e1 = $0E; e2 = $10; record();    // '1', '.', '0'

    // Move cursor down before the harness output so it doesn't
    // overlap the screen rows we just verified.
    Stdio.setCursor(0, 10);

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}
