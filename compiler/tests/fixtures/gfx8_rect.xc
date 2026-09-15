//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx8_rect.xc — Gfx8.rect (outline) and Gfx8.fillRect.
//
// rect: 4-edge perimeter, corners visited twice (no-op for pen=1
// OR-with-same-mask, idempotent for pen=0 AND-with-same-inverted-
// mask). Tests pin the corner bytes for a small rect plus an
// interior pixel that must remain unset.
//
// fillRect: tight loop of hlines, each row using the bulk-byte
// fast path. Tests pin a few row bytes plus a row outside the
// rectangle.
//
// Both functions take inclusive endpoints, so `rect(0,0,9,9)` is
// the perimeter of a 10x10 square.

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx8.xc"

void main(void)
{
    Assert.reset();
    u8* buf = new u8[7680];
    Gfx8* g = new Gfx8(buf);
    g.setPen(1);

    // ── rect outline ───────────────────────────────────────────
    // 8x8 perimeter at (0, 0) → (7, 7). Top row 0 byte 0 = $FF
    // (8 pixels). Bottom row 7 byte 0 = $FF too. Middle rows
    // (1..6) byte 0 must have only bits 7 and 0 set ($81 — left
    // and right edges).
    g.setFillColor(0); g.clear();
    g.rect(0, 0, 7, 7);
    Assert.isEqual(buf[0], $FF);          // T1 — top edge byte 0
    Assert.isEqual(buf[7 * 40], $FF);     // T2 — bottom edge
    Assert.isEqual(buf[1 * 40], $81);     // T3 — row 1 left+right
    Assert.isEqual(buf[3 * 40], $81);     // T4 — row 3
    Assert.isEqual(buf[6 * 40], $81);     // T5 — row 6
    Assert.isEqual(buf[8 * 40], $00);     // T6 — row 8 (outside)

    // 16x4 perimeter at (8, 0) → (23, 3). Top row 0 spans bytes
    // 1 (bits 7..0 = $FF) and byte 2 (bits 7..0 = $FF). Right
    // edge column 23 is byte 2 bit 0 = $01. Left edge column 8
    // is byte 1 bit 7 = $80.
    g.clear();
    g.rect(8, 0, 23, 3);
    Assert.isEqual(buf[1] & $FF, $FF);    // T7 — top row, byte 1 all set
    Assert.isEqual(buf[2] & $FF, $FF);    // T8 — top row, byte 2 all set
    Assert.isEqual(buf[1 * 40 + 1] & $80, $80);  // T9 — row 1 left
    Assert.isEqual(buf[1 * 40 + 2] & $01, $01);  // T10 — row 1 right
    Assert.isEqual(buf[1 * 40 + 1] & $7F, $00);  // T11 — row 1 between edges

    // ── fillRect ───────────────────────────────────────────────
    // 16x3 fill at (8, 0) → (23, 2). Each of rows 0,1,2 has byte
    // 1 = byte 2 = $FF. Row 3 must be $00.
    g.clear();
    g.fillRect(8, 0, 23, 2);
    Assert.isEqual(buf[0 * 40 + 1], $FF);  // T12
    Assert.isEqual(buf[0 * 40 + 2], $FF);  // T13
    Assert.isEqual(buf[1 * 40 + 1], $FF);  // T14
    Assert.isEqual(buf[2 * 40 + 2], $FF);  // T15
    Assert.isEqual(buf[3 * 40 + 1], $00);  // T16 — row 3 untouched

    // ── pen=0 over $FF background ──────────────────────────────
    // Erase a 4x4 hole at (4, 4) → (7, 7) on a $FF screen.
    // Inside the hole all pixels are $00. Around it (e.g.
    // row 3, row 8) stays $FF.
    g.setFillColor(1); g.clear();
    g.setPen(0);
    g.fillRect(4, 4, 7, 7);
    Assert.isEqual(buf[3 * 40] & $0F, $0F);   // T17 — row 3 (above) untouched
    Assert.isEqual(buf[4 * 40] & $0F, $00);   // T18 — row 4 cleared bits 4..7
    Assert.isEqual(buf[5 * 40] & $0F, $00);   // T19
    Assert.isEqual(buf[7 * 40] & $0F, $00);   // T20
    Assert.isEqual(buf[8 * 40] & $0F, $0F);   // T21 — row 8 (below) untouched
    Assert.isEqual(buf[4 * 40] & $F0, $F0);   // T22 — row 4 left half stays set

    Stdio.printf("DONE 22\n");
    return;
}
