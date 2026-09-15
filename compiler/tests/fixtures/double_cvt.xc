//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// double_cvt.xc — regression test for int→double conversion routines.
//
// u8/i8/u16/i16 → dp currently delegate to their fp counterparts
// and zero-extend the lower mantissa bytes; those values fit
// entirely in the 24-bit fp mantissa so the round-trip is exact.
// u32/i32 → dp go through a direct 48-bit normalisation so that
// $FFFFFFFF encodes as 2^32-1 exactly rather than losing the
// bottom 8 bits to fp's 24-bit mantissa.

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

    // T1: u32ToDp(1) = 1.0
    asm { LDA #$01 : STA $B0 : LDA #$00 : STA $B1 : STA $B2 : STA $B3
          JSR u32ToDp
          LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
          LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
    e0 = $00; e1 = $00; e2 = $00; e3 = $00;
    e4 = $00; e5 = $00; e6 = $00; e7 = $00; record();

    // T2: u32ToDp(0) = 0
    asm { LDA #$00 : STA $B0 : STA $B1 : STA $B2 : STA $B3
          JSR u32ToDp
          LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
          LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
    e0 = $10; e1 = $00; e2 = $00; e3 = $00;
    e4 = $00; e5 = $00; e6 = $00; e7 = $00; record();

    // T3: u32ToDp(2) = 2.0
    asm { LDA #$02 : STA $B0 : LDA #$00 : STA $B1 : STA $B2 : STA $B3
          JSR u32ToDp
          LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
          LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
    e0 = $00; e1 = $01; e2 = $00; e3 = $00;
    e4 = $00; e5 = $00; e6 = $00; e7 = $00; record();

    // T4: u32ToDp(3) = 3.0   (mantissa top bit set)
    asm { LDA #$03 : STA $B0 : LDA #$00 : STA $B1 : STA $B2 : STA $B3
          JSR u32ToDp
          LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
          LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
    e0 = $00; e1 = $01; e2 = $80; e3 = $00;
    e4 = $00; e5 = $00; e6 = $00; e7 = $00; record();

    // T5: u32ToDp($FFFFFFFF) = 2^32 - 1, exact in dp (would lose
    //     low bits in fp). Expected exp = 31, mantissa =
    //     FF FF FF FE 00 00 (representing 1 - 2^-31).
    asm { LDA #$FF : STA $B0 : STA $B1 : STA $B2 : STA $B3
          JSR u32ToDp
          LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
          LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
    e0 = $00; e1 = $1F; e2 = $FF; e3 = $FF;
    e4 = $FF; e5 = $FE; e6 = $00; e7 = $00; record();

    // T6: u32ToDp($80000000) = 2^31, exact
    asm { LDA #$00 : STA $B0 : STA $B1 : STA $B2 : LDA #$80 : STA $B3
          JSR u32ToDp
          LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
          LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
    e0 = $00; e1 = $1F; e2 = $00; e3 = $00;
    e4 = $00; e5 = $00; e6 = $00; e7 = $00; record();

    // T7: i32ToDp(-1) = -1.0
    asm { LDA #$FF : STA $B0 : STA $B1 : STA $B2 : STA $B3
          JSR i32ToDp
          LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
          LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
    e0 = $01; e1 = $00; e2 = $00; e3 = $00;
    e4 = $00; e5 = $00; e6 = $00; e7 = $00; record();

    // T8: i32ToDp(1) = 1.0
    asm { LDA #$01 : STA $B0 : LDA #$00 : STA $B1 : STA $B2 : STA $B3
          JSR i32ToDp
          LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
          LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
    e0 = $00; e1 = $00; e2 = $00; e3 = $00;
    e4 = $00; e5 = $00; e6 = $00; e7 = $00; record();

    // T9: u8ToDp (via u8ToFp + zero-extend): 42 = 2.625 * 2^4,
    //     mantissa = 0.3125 * 2^24 bits = $500000 at top 3,
    //     zeros below. Expected {$00, $05, $50, $00, $00, $00, $00, $00}.
    asm { LDA #$2A : STA $B0
          JSR u8ToDp
          LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
          LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
    e0 = $00; e1 = $05; e2 = $50; e3 = $00;
    e4 = $00; e5 = $00; e6 = $00; e7 = $00; record();

    // T10: i16ToDp(-100) = -100.0 = -1.5625 * 2^6,
    //      mantissa 0.5625 = bit 0 + bit 2 = $90_00_00 at top,
    //      zeros below. Expected {$01, $06, $90, $00, $00, $00, $00, $00}.
    asm { LDA #$9C : STA $B0 : LDA #$FF : STA $B1
          JSR i16ToDp
          LDA $B0 : STA r0 : LDA $B1 : STA r1 : LDA $B2 : STA r2 : LDA $B3 : STA r3
          LDA $B4 : STA r4 : LDA $B5 : STA r5 : LDA $B6 : STA r6 : LDA $B7 : STA r7 }
    e0 = $01; e1 = $06; e2 = $90; e3 = $00;
    e4 = $00; e5 = $00; e6 = $00; e7 = $00; record();

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}