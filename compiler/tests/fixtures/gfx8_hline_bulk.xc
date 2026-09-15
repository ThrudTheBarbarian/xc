//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx8_hline_bulk.xc — Gfx8.hline bulk-byte fast path.
//
// hline now splits the line into three sections: a left
// partial byte (bits bitLo..7), a middle run of full $FF
// (or $00) bytes, and a right partial byte (bits 0..bitHi).
// Mask-table lookups drive the partials so each section is
// one read-modify-write; the middle run is plain STA. Old
// per-pixel implementation called inline:plot per column,
// which is ~10x slower for full-width lines.
//
// Coverage:
//   Single-byte case (byteLo == byteHi)       — T1, T2, T3
//   Multi-byte set with byteLo == 0/byteHi==7 — T4, T5
//   Mid-byte boundaries (partial both ends)   — T6, T7
//   Full-width line, no partials              — T8, T9
//   pen=0 over an all-$FF background          — T10, T11
//   Single-byte clear over $FF background     — T12, T13

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx8.xc"

void main(void)
{
    Assert.reset();
    u8* buf = new u8[7680];
    Gfx8* g = new Gfx8(buf);

    // ── Single-byte case ──────────────────────────────────────
    // hline(2, 5, 0): bits 2..5 of byte 0 set = $3C.
    g.setFillColor(0); g.clear();
    g.setPen(1); g.hline(2, 5, 0);
    Assert.isEqual(buf[0], $3C);

    // hline(0, 0, 0): single bit, leftmost = $80.
    g.setFillColor(0); g.clear();
    g.hline(0, 0, 0);
    Assert.isEqual(buf[0], $80);

    // hline(7, 7, 0): rightmost bit = $01.
    g.setFillColor(0); g.clear();
    g.hline(7, 7, 0);
    Assert.isEqual(buf[0], $01);

    // ── Multi-byte, left edge on byte boundary ───────────────
    // hline(0, 15, 0): bytes 0 and 1, left and right both
    // fully covered (bitLo=0, bitHi=7). Both bytes -> $FF.
    g.setFillColor(0); g.clear();
    g.hline(0, 15, 0);
    Assert.isEqual(buf[0], $FF);
    Assert.isEqual(buf[1], $FF);

    // ── Mid-byte boundaries ──────────────────────────────────
    // hline(3, 12, 0): byteLo=0 (bits 3..7 = $1F), middle
    // none (byteHi=1), byteHi=1 (bits 0..4 = $F8).
    g.setFillColor(0); g.clear();
    g.hline(3, 12, 0);
    Assert.isEqual(buf[0], $1F);
    Assert.isEqual(buf[1], $F8);

    // ── Full-width line ──────────────────────────────────────
    // hline(0, 319, 0): byte 0..39 all $FF.
    g.setFillColor(0); g.clear();
    g.hline(0, 319, 0);
    Assert.isEqual(buf[0], $FF);
    Assert.isEqual(buf[39], $FF);

    // ── pen=0 over $FF background ────────────────────────────
    // Fill with 1, then clear pixels 5..10 on row 0:
    //   byte 0 pixels 5,6,7 = byte-bits 2,1,0 cleared,
    //          $FF AND ~$07 = $F8 (byte-bits 7..3 retained).
    //   byte 1 pixels 8,9,10 = byte-bits 7,6,5 cleared,
    //          $FF AND ~$E0 = $1F (byte-bits 4..0 retained).
    g.setFillColor(1); g.clear();
    g.setPen(0); g.hline(5, 10, 0);
    Assert.isEqual(buf[0], $F8);
    Assert.isEqual(buf[1], $1F);

    // Single-byte clear: hline(2, 5, 0) over $FF leaves $C3
    // (bits 2..5 cleared).
    g.setFillColor(1); g.clear();
    g.hline(2, 5, 0);
    Assert.isEqual(buf[0], $C3);

    // bytes outside range 5..10 untouched on row 0.
    Assert.isEqual(buf[39], $FF);

    Stdio.printf("DONE 14\n");
    return;
}
