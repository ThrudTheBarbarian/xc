//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx8_circle.xc — Gfx8.circle (outline) and Gfx8.fillCircle.
//
// Bresenham 8-octant. Tests pin specific pixel positions for
// small radii; visual correctness for larger radii is verified
// via spot-checks rather than per-pixel.

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx8.xc"

void main(void)
{
    Assert.reset();
    u8* buf = new u8[7680];
    Gfx8* g = new Gfx8(buf);
    g.setPen(1);

    // ── r=0 → single pixel ────────────────────────────────────
    g.setFillColor(0); g.clear();
    g.circle(8, 8, 0);
    Assert.isEqual(buf[8 * 40 + 1] & $80, $80);   // T1 — (8, 8) lit

    // ── r=1 → cross of 4 pixels, centre not lit ──────────────
    g.clear();
    g.circle(8, 8, 1);
    Assert.isEqual(buf[7 * 40 + 1] & $80, $80);   // T2 — (8, 7)
    Assert.isEqual(buf[9 * 40 + 1] & $80, $80);   // T3 — (8, 9)
    Assert.isEqual(buf[8 * 40 + 0] & $01, $01);   // T4 — (7, 8) byte 0 bit 0
    Assert.isEqual(buf[8 * 40 + 1] & $40, $40);   // T5 — (9, 8) byte 1 bit 6
    Assert.isEqual(buf[8 * 40 + 1] & $80, $00);   // T6 — (8, 8) NOT lit

    // ── r=2 → 12 pixels (4 axis + 8 near-diagonal) ───────────
    g.clear();
    g.circle(10, 10, 2);
    // Axis points: (12, 10), (8, 10), (10, 8), (10, 12).
    // Pixel (12, 10): byte 12/8=1, bit $80>>(12&7)=$80>>4=$08.
    // Pixel (8, 10):  byte 8/8=1,  bit $80>>0=$80.
    // Pixel (10, 8):  byte 10/8=1, bit $80>>(10&7)=$80>>2=$20.
    // Pixel (10, 12): same byte, bit $20 in row 12.
    Assert.isEqual(buf[10 * 40 + 1] & $08, $08);  // T7 — (12, 10)
    Assert.isEqual(buf[10 * 40 + 1] & $80, $80);  // T8 — (8, 10)
    Assert.isEqual(buf[8  * 40 + 1] & $20, $20);  // T9 — (10, 8)
    Assert.isEqual(buf[12 * 40 + 1] & $20, $20);  // T10 — (10, 12)
    // Diagonal point (11, 12): byte 1, $80>>3=$10.
    Assert.isEqual(buf[12 * 40 + 1] & $10, $10);  // T11

    // ── fillCircle r=0 → single pixel ────────────────────────
    g.clear();
    g.fillCircle(20, 20, 0);
    Assert.isEqual(buf[20 * 40 + 2] & $08, $08);  // T12 — (20, 20) byte 2 bit 3

    // ── fillCircle r=2 ──────────────────────────────────────
    // r=2 disk centred at (20, 20). Centre row (y=20) spans
    // x = 18..22 inclusive (5 pixels). Top/bottom rows (y=18,
    // y=22) span x = 19..21 (3 pixels). Outside (y=17, y=23)
    // empty.
    g.clear();
    g.fillCircle(20, 20, 2);
    // Centre row 20: x=18..22 → byte 2 bits 5,4,3,2,1 = $3E.
    Assert.isEqual(buf[20 * 40 + 2] & $3E, $3E); // T13 — full centre row
    // Row 19 and 21: x=18..22 (full r=2 disk has these wide).
    Assert.isEqual(buf[19 * 40 + 2] & $3E, $3E); // T14
    Assert.isEqual(buf[21 * 40 + 2] & $3E, $3E); // T15
    // Top/bottom rows 18 and 22: x=19..21 → bits 4,3,2 = $1C.
    Assert.isEqual(buf[18 * 40 + 2] & $1C, $1C); // T16
    Assert.isEqual(buf[22 * 40 + 2] & $1C, $1C); // T17
    // Just outside the disk: row 17 and row 23 untouched.
    Assert.isEqual(buf[17 * 40 + 2], $00);       // T18
    Assert.isEqual(buf[23 * 40 + 2], $00);       // T19

    // ── pen=0 over $FF, fillCircle erases the disk ─────────
    g.setFillColor(1); g.clear();
    g.setPen(0);
    g.fillCircle(20, 20, 2);
    // Same disk as above, now $00 instead of $FF on the disk
    // bits and $FF outside.
    Assert.isEqual(buf[20 * 40 + 2] & $3E, $00); // T20 — centre row cleared
    Assert.isEqual(buf[18 * 40 + 2] & $1C, $00); // T21 — top row cleared
    Assert.isEqual(buf[17 * 40 + 2], $FF);       // T22 — row above stays set

    Stdio.printf("DONE 22\n");
    return;
}
