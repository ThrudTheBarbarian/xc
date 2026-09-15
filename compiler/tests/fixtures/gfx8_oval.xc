//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx8_oval.xc — Gfx8.oval / Gfx8.fillOval midpoint-ellipse.
//
// Verifies the cardinal axial points (top, bottom, left, right)
// of a few small ovals and the degenerate axes (rx=0, ry=0).
// fillOval gets a coverage check at the centre + a row interior
// to the ellipse + a row outside it.
//
// Pixel layout (GR.8 1bpp): byte = y*40 + (x>>3),
// bitmask = $80 >> (x & 7).

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx8.xc"

void main(void)
{
    Assert.reset();
    u8* buf = new u8[7680];
    Gfx8* g = new Gfx8(buf);
    g.setPen(1);

    // ── Outline oval at (40, 20), rx=8 ry=4 ──────────────────
    // axial points: top (40,16), bottom (40,24), left (32,20),
    // right (48,20). All have x%8 = 0, so bit = $80.
    g.setFillColor(0); g.clear();
    g.oval(40, 20, 8, 4);
    Assert.isEqual(buf[16 * 40 + 5] & $80, $80);  // T1 top
    Assert.isEqual(buf[24 * 40 + 5] & $80, $80);  // T2 bottom
    Assert.isEqual(buf[20 * 40 + 4] & $80, $80);  // T3 left
    Assert.isEqual(buf[20 * 40 + 6] & $80, $80);  // T4 right
    // Centre (40,20) must NOT be lit (outline only).
    Assert.isEqual(buf[20 * 40 + 5] & $80, $00);  // T5

    // ── Outline oval at (50, 30), rx=9 ry=6 — varied bit pos ──
    // top (50,24): byte = 24*40 + 50/8 = 24*40 + 6 = 966; bit
    // = $80 >> (50 & 7 = 2) = $20.
    g.setFillColor(0); g.clear();
    g.oval(50, 30, 9, 6);
    Assert.isEqual(buf[24 * 40 + 6] & $20, $20);  // T6 top
    Assert.isEqual(buf[36 * 40 + 6] & $20, $20);  // T7 bottom
    // left (41,30): byte = 30*40 + 41/8 = 1205; bit = $80 >>
    // (41 & 7 = 1) = $40.
    Assert.isEqual(buf[30 * 40 + 5] & $40, $40);  // T8 left
    // right (59,30): byte = 30*40 + 59/8 = 1207; bit = $80 >>
    // (59 & 7 = 3) = $10.
    Assert.isEqual(buf[30 * 40 + 7] & $10, $10);  // T9 right

    // ── Filled oval at (40, 20), rx=8 ry=4 ──────────────────
    // Same shape, but fill should light the entire interior.
    g.setFillColor(0); g.clear();
    g.fillOval(40, 20, 8, 4);
    // Centre is lit.
    Assert.isEqual(buf[20 * 40 + 5] & $80, $80);  // T10 centre
    // All four axial points still lit (boundary).
    Assert.isEqual(buf[16 * 40 + 5] & $80, $80);  // T11 top
    Assert.isEqual(buf[24 * 40 + 5] & $80, $80);  // T12 bottom
    Assert.isEqual(buf[20 * 40 + 4] & $80, $80);  // T13 left
    Assert.isEqual(buf[20 * 40 + 6] & $80, $80);  // T14 right
    // A row inside the oval (y=18, 2 above centre) is wide:
    // covers cx-something through cx+something. Check (40,18)
    // and (44,18) — both should be lit.
    Assert.isEqual(buf[18 * 40 + 5] & $80, $80);  // T15 inside (40,18)
    Assert.isEqual(buf[18 * 40 + 5] & $08, $08);  // T16 inside (44,18) — bit $80>>4
    // Outside the oval (y=15, above the top): no pixels lit.
    Assert.isEqual(buf[15 * 40 + 5], $00);        // T17 above
    Assert.isEqual(buf[25 * 40 + 5], $00);        // T18 below

    // ── Degenerate cases ────────────────────────────────────
    // rx=0, ry=0: single plot.
    g.setFillColor(0); g.clear();
    g.oval(80, 50, 0, 0);
    Assert.isEqual(buf[50 * 40 + 10] & $80, $80); // T19 (80,50)
    g.setFillColor(0); g.clear();
    g.fillOval(80, 50, 0, 0);
    Assert.isEqual(buf[50 * 40 + 10] & $80, $80); // T20 fill (80,50)

    // ── Pen=0 erases through fillOval ───────────────────────
    g.setFillColor(1); g.clear();   // all $FF
    g.setPen(0);
    g.fillOval(40, 20, 8, 4);
    // Centre erased.
    Assert.isEqual(buf[20 * 40 + 5] & $80, $00);  // T21 centre erased
    // Far-away byte still $FF.
    Assert.isEqual(buf[100 * 40 + 5], $FF);       // T22 untouched

    Stdio.printf("DONE 22\n");
    return;
}
