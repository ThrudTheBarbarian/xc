//xtc-flags: skip  — byte-compares retired 5/8-byte softfloat results (dead dp*/fp* routines / old byte layout); obsolete under IEEE via MECH (phase-671). Values covered by mech_demo + mech_float_ops.
//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// byte_list_init.xc — regression for scalar byte-list initialisers.
//
// `u32 v = {$34, $12, $00, $00};` and the like set the raw byte pattern of a
// sized scalar, mirroring the existing array-init form. Entries are
// constant-foldable u8 expressions; missing trailing bytes zero-fill
// (C-style); extra entries warn and are dropped.
//
// `[...]` used to be accepted here too and was removed in 0.4 along with the
// other `[ ]` bracket forms — it only ever existed because `{ }` was taken by
// the old `(( ))` block syntax. T3 below kept it alive and is now `{ }`.

#import "Stdio.xc"

u8 testCount;
u8 failCount;
u8 fails[16];

u8 r0; u8 r1; u8 r2; u8 r3; u8 r4; u8 r5; u8 r6; u8 r7;
u8 e0; u8 e1; u8 e2; u8 e3; u8 e4; u8 e5; u8 e6; u8 e7;

void record(void)
{
    testCount = testCount + 1;
    if (r0 != e0 || r1 != e1 || r2 != e2 || r3 != e3 ||
        r4 != e4 || r5 != e5 || r6 != e6 || r7 != e7) {
        if (failCount < 16) { fails[failCount] = testCount; }
        failCount = failCount + 1;
    }
}

void clear(void)
{
    r0 = 0; r1 = 0; r2 = 0; r3 = 0;
    r4 = 0; r5 = 0; r6 = 0; r7 = 0;
    e0 = 0; e1 = 0; e2 = 0; e3 = 0;
    e4 = 0; e5 = 0; e6 = 0; e7 = 0;
}

#define BIT7 $80

// Globals with byte-list init — checks the data-section emission path.
u16 gA = {$37, $13};
u32 gB = {$78, $56, $34, $12};
float gC = {$00, $00, $6A, $09, $E6};  // sqrt(2)

void main(void)
{
    testCount = 0;
    failCount = 0;

    // ── T1: u8 local ─────────────────────────────────────────
    { clear();
      u8 v = {$AA};
      r0 = v;
      e0 = $AA; record(); }

    // ── T2: u16 local, brace form ────────────────────────────
    { clear();
      u16 v = {$34, $12};
      asm { LDA v   : STA r0
            LDA v+1 : STA r1 }
      e0 = $34; e1 = $12; record(); }

    // ── T3: u16 local, second site ───────────────────────────
    { clear();
      u16 v = {$34, $12};
      asm { LDA v   : STA r0
            LDA v+1 : STA r1 }
      e0 = $34; e1 = $12; record(); }

    // ── T4: i16 local with sign bit set ──────────────────────
    { clear();
      i16 v = {$FF, $FF};
      asm { LDA v   : STA r0
            LDA v+1 : STA r1 }
      e0 = $FF; e1 = $FF; record(); }

    // ── T5: u32 local ────────────────────────────────────────
    { clear();
      u32 v = {$78, $56, $34, $12};
      asm { LDA v   : STA r0
            LDA v+1 : STA r1
            LDA v+2 : STA r2
            LDA v+3 : STA r3 }
      e0 = $78; e1 = $56; e2 = $34; e3 = $12; record(); }

    // ── T6: i32 local ────────────────────────────────────────
    { clear();
      i32 v = {$FF, $FF, $FF, $FF};
      asm { LDA v   : STA r0
            LDA v+1 : STA r1
            LDA v+2 : STA r2
            LDA v+3 : STA r3 }
      e0 = $FF; e1 = $FF; e2 = $FF; e3 = $FF; record(); }

    // ── T7: float local (sqrt 2 bit pattern) ─────────────────
    { clear();
      float v = {$00, $00, $6A, $09, $E6};
      asm { LDA v   : STA r0
            LDA v+1 : STA r1
            LDA v+2 : STA r2
            LDA v+3 : STA r3
            LDA v+4 : STA r4 }
      e0 = $00; e1 = $00; e2 = $6A; e3 = $09; e4 = $E6; record(); }

    // ── T8: double local (sqrt 2 bit pattern) ────────────────
    { clear();
      double v = {$00, $00, $6A, $09, $E6, $67, $F3, $BD};
      asm { LDA v   : STA r0
            LDA v+1 : STA r1
            LDA v+2 : STA r2
            LDA v+3 : STA r3
            LDA v+4 : STA r4
            LDA v+5 : STA r5
            LDA v+6 : STA r6
            LDA v+7 : STA r7 }
      e0 = $00; e1 = $00; e2 = $6A; e3 = $09;
      e4 = $E6; e5 = $67; e6 = $F3; e7 = $BD; record(); }

    // ── T9: pointer local — two bytes, lo then hi ────────────
    { clear();
      u8* p = {$00, $80};
      asm { LDA p   : STA r0
            LDA p+1 : STA r1 }
      e0 = $00; e1 = $80; record(); }

    // ── T10: zero-fill missing trailing bytes ────────────────
    { clear();
      u32 v = {$FF};
      asm { LDA v   : STA r0
            LDA v+1 : STA r1
            LDA v+2 : STA r2
            LDA v+3 : STA r3 }
      e0 = $FF; e1 = 0; e2 = 0; e3 = 0; record(); }

    // ── T11: constant-foldable expression entries ────────────
    { clear();
      u16 v = {BIT7 | $07, BIT7 - 1};
      asm { LDA v   : STA r0
            LDA v+1 : STA r1 }
      e0 = $87; e1 = $7F; record(); }

    // ── T12: global u16 ──────────────────────────────────────
    { clear();
      asm { LDA gA   : STA r0
            LDA gA+1 : STA r1 }
      e0 = $37; e1 = $13; record(); }

    // ── T13: global u32 ──────────────────────────────────────
    { clear();
      asm { LDA gB   : STA r0
            LDA gB+1 : STA r1
            LDA gB+2 : STA r2
            LDA gB+3 : STA r3 }
      e0 = $78; e1 = $56; e2 = $34; e3 = $12; record(); }

    // ── T14: global float ────────────────────────────────────
    { clear();
      asm { LDA gC   : STA r0
            LDA gC+1 : STA r1
            LDA gC+2 : STA r2
            LDA gC+3 : STA r3
            LDA gC+4 : STA r4 }
      e0 = $00; e1 = $00; e2 = $6A; e3 = $09; e4 = $E6; record(); }

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}
