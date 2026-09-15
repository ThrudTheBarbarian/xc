//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx8_pie.xc — Gfx8.pie outline (arc + radial chords) and
// fillPie (defers to fillArc since a quadrant-mask filled disk
// IS a pie slice).
//
// pie() draws arc(cx,cy,r,mask) plus a radial line at each axis
// where the two adjacent quadrants disagree on the mask:
//   bit 0 (TR) ^ bit 3 (BR)  → right axis  (cx+r, cy)
//   bit 0 (TR) ^ bit 1 (TL)  → top axis    (cx,   cy-r)
//   bit 1 (TL) ^ bit 2 (BL)  → left axis   (cx-r, cy)
//   bit 2 (BL) ^ bit 3 (BR)  → bottom axis (cx,   cy+r)
//
// So mask=$01 (TR only) draws right + top radii; mask=$03 (top
// half) draws right + left; mask=$0F (full) draws no radii (it's
// a complete circle, no slice).

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx8.xc"

void main(void)
{
    Assert.reset();
    u8* buf = new u8[7680];
    Gfx8* g = new Gfx8(buf);
    g.setPen(1);

    // ── pie r=0 plots centre regardless of mask ───────────
    g.setFillColor(0); g.clear();
    g.pie(40, 30, 0, $01);
    Assert.isEqual(buf[30 * 40 + 5] & $80, $80);    // T1

    // ── pie quadrants=0 is a no-op ────────────────────────
    g.clear();
    g.pie(40, 30, 5, 0);
    Assert.isEqual(buf[30 * 40 + 5], $00);          // T2

    // ── pie mask=$01 (TR only): arc + right + top radii ──
    g.clear();
    g.pie(40, 30, 5, $01);
    // Right radius: pixels (40, 30) through (45, 30) on the
    // centre row should be lit (the rightward axis).
    Assert.isEqual(buf[30 * 40 + 5] & $80, $80);    // T3 (40,30)
    Assert.isEqual(buf[30 * 40 + 5] & $40, $40);    // T4 (41,30)
    Assert.isEqual(buf[30 * 40 + 5] & $04, $04);    // T5 (45,30)
    // Top radius: pixels (40, 30) through (40, 25) on column 40.
    Assert.isEqual(buf[26 * 40 + 5] & $80, $80);    // T6 (40,26)
    Assert.isEqual(buf[25 * 40 + 5] & $80, $80);    // T7 (40,25)
    // Left axis (40-5, 30) = (35,30) — must NOT be lit (the
    // pie doesn't cross the left axis).
    Assert.isEqual(buf[30 * 40 + 4] & $08, $00);    // T8

    // ── pie mask=$03 (TR + TL = top half): right + left radii ─
    // Top axis is INSIDE the pie now (between two "in"
    // quadrants) so it's NOT a chord.
    g.clear();
    g.pie(40, 30, 5, $03);
    // Right axis: lit
    Assert.isEqual(buf[30 * 40 + 5] & $04, $04);    // T9  (45,30)
    // Left axis: lit
    Assert.isEqual(buf[30 * 40 + 4] & $08, $08);    // T10 (35,30)
    // Top axis interior pixel (40, 28) must NOT be lit
    // (the pie crosses this axis without a chord).
    Assert.isEqual(buf[28 * 40 + 5] & $80, $00);    // T11

    // ── pie mask=$0F (full): no radii, full circle only ──
    g.clear();
    g.pie(40, 30, 5, $0F);
    // No interior radii — centre column above/below centre
    // row should be untouched (only the circle outline).
    Assert.isEqual(buf[28 * 40 + 5] & $80, $00);    // T12 (40,28)
    Assert.isEqual(buf[32 * 40 + 5] & $80, $00);    // T13 (40,32)
    // The arc itself is drawn, so the topmost point (40,25)
    // is lit.
    Assert.isEqual(buf[25 * 40 + 5] & $80, $80);    // T14 (40,25)

    // ── fillPie matches fillArc bit-for-bit ──────────────
    // Fill a TR slice with both methods and compare a
    // representative interior pixel + an exterior pixel.
    g.clear();
    g.fillPie(40, 30, 5, $01);
    u8 pieByte = buf[28 * 40 + 5];                  // (~,28) on the slice

    g.clear();
    g.fillArc(40, 30, 5, $01);
    u8 arcByte = buf[28 * 40 + 5];

    Assert.isEqual((u16)pieByte, (u16)arcByte);     // T15

    Stdio.printf("DONE 15\n");
    return;
}
