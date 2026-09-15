//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// printDouble's `STA (self),Y` plumbing (phase-171: arm64 backend now
// assembles inline asm verbatim).
// printf_double.xc — Tier 1 plumbing test for the `double` type.
//
// Exercises the end-to-end path added for 8-byte doubles:
//   - Parse the `d` suffix on a decimal literal (lex → 8-byte payload).
//   - Resolve the literal as `double` in sema.
//   - Allocate 8 bytes of storage for a `double` local and store an
//     8-byte encoded literal into it.
//   - Pass a `double` to a varargs function (8-byte pack into the
//     printf buffer at $04B2).
//   - printf `%lf` specifier dispatch → pullDouble (8 bytes from
//     buffer into $B0-$B7) → printDouble → dp2Asc (a full 48-bit
//     mantissa conversion emitting 10 fractional digits).
//
// The test writes to screen RAM and reads the first three cells back
// through Stdio's screenBase ivar, comparing them to the Atari screen
// codes for '1', '.', '5' = $11, $0E, $15 (T1) and '2', '.', '5' =
// $12, $0E, $15 (T2). Only the first three cells are checked so the
// test stays robust against the extra fractional digits vs. `%f`.

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

    // ── T1: double literal via printf %lf ─────────────────────
    Stdio.setCursor(0, 0);
    Stdio.printf("%lf", 1.5d);
    asm {
        LDA __sdata_Stdio + _ivar_Stdio_screenBase : STA $86
        LDA __sdata_Stdio + _ivar_Stdio_screenBase+1 : STA $87
        LDY #$00 : LDA ($86),Y : STA r0
        LDY #$01 : LDA ($86),Y : STA r1
        LDY #$02 : LDA ($86),Y : STA r2
    }
    e0 = $11; e1 = $0E; e2 = $15; record();

    // ── T2: double local via printf %lf ───────────────────────
    Stdio.setCursor(0, 1);
    { double a = 2.5d;
      Stdio.printf("%lf", a); }
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

    Stdio.setCursor(0, 10);

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}
