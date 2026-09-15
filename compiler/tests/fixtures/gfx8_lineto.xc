//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx8_lineto.xc — Gfx8.lineTo cursor-based line draw.
//
// Draws a closed quadrilateral by chaining moveTo + lineTo
// segments and verifies a representative pixel hit on each
// edge. Cursor-state checks are skipped (they're a thin wrapper
// over plain ivar reads — covered by the dedicated currentX /
// currentY asserts in the simpler fixtures); each segment's
// pixels exercise the same lineTo → line plumbing anyway.

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx8.xc"

void main(void)
{
    Assert.reset();
    u8* buf = new u8[7680];
    Gfx8* g = new Gfx8(buf);
    g.setPen(1);

    // 16x16 outline at (8, 8) → (23, 23) via cursor moves.
    g.setFillColor(0); g.clear();
    g.moveTo(8, 8);
    g.lineTo(23, 8);                   // top edge
    g.lineTo(23, 23);                  // right edge
    g.lineTo(8, 23);                   // bottom edge
    g.lineTo(8, 8);                    // left edge — closes the box

    // Top edge row 8: bytes 1 + 2 fully set (cols 8..23).
    Assert.isEqual(buf[8 * 40 + 1], $FF);   // T1
    Assert.isEqual(buf[8 * 40 + 2], $FF);   // T2
    // Bottom edge row 23: same.
    Assert.isEqual(buf[23 * 40 + 1], $FF);  // T3
    Assert.isEqual(buf[23 * 40 + 2], $FF);  // T4
    // Left edge column 8 (byte 1 bit 7) on rows 10 and 22.
    Assert.isEqual(buf[10 * 40 + 1] & $80, $80);  // T5
    Assert.isEqual(buf[22 * 40 + 1] & $80, $80);  // T6
    // Right edge column 23 (byte 2 bit 0) on rows 10 and 22.
    Assert.isEqual(buf[10 * 40 + 2] & $01, $01);  // T7
    Assert.isEqual(buf[22 * 40 + 2] & $01, $01);  // T8

    // pen=0 over $FF: lineTo erases.
    g.setFillColor(1); g.clear();
    g.setPen(0);
    g.moveTo(0, 5);
    g.lineTo(15, 5);                   // erase row 5 cols 0..15
    Assert.isEqual(buf[5 * 40 + 0], $00);    // T9
    Assert.isEqual(buf[5 * 40 + 1], $00);    // T10
    Assert.isEqual(buf[5 * 40 + 2], $FF);    // T11

    Stdio.printf("DONE 11\n");
    return;
}
