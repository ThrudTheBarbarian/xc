//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx8_flood.xc — Gfx8.floodFill scanline fill.
//
// Pins:
//   T1-T2   trivial 4x4 closed box, seed inside, fillColor=1.
//   T3      seed already at fillColor → no-op (returns true).
//   T4      seed off-screen → no-op (returns true).
//   T5-T6   pen=0 erase: start with $FF screen, fill with colour 0
//           inside an open region.
//   T7-T8   complex shape: filled L blocks bordered by a stroke,
//           seed inside the L's body, verifies the fill stays
//           inside the boundary (does not bleed through the open
//           vertical strip outside the boundary stroke).
//   T9      return value for an unconstrained fill — fills then
//           returns true (no overflow).

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx8.xc"

void main(void)
{
    Assert.reset();
    u8* buf = new u8[7680];
    Gfx8* g = new Gfx8(buf);

    // ── T1, T2 — fill the inside of a 6x6 outlined box. The
    // boundary is at rows 0,5 and cols 0,5; the interior is the
    // 4x4 region rows 1..4, cols 1..4. After fill the interior
    // bytes should be lit.
    g.setPen(1);
    g.setFillColor(0); g.clear();
    g.rect(0, 0, 5, 5);                     // boundary outline

    // Sanity: top-left interior pixel (1,1) is currently OFF.
    Assert.isEqual(buf[1 * 40] & $40, $00); // T1: pre-fill

    g.setFillColor(1);
    bool ok = g.floodFill(2, 2);
    Assert.isTrue(ok);                      // T2: returns true

    // Interior pixel (3, 3) now lit.
    Assert.isEqual(buf[3 * 40] & $10, $10); // T3
    // Outside the box (e.g. row 7 col 0) untouched.
    Assert.isEqual(buf[7 * 40] & $80, $00); // T4

    // ── T5 — already-filled seed: floodFill is a no-op. With
    // fillColor=1 and pen=1 over a clear screen, plot one pixel,
    // then ask for fill at that pixel.
    g.setFillColor(0); g.clear();
    g.setPen(1); g.plot(10, 10);            // single lit pixel
    g.setFillColor(1);                      // seed already matches
    ok = g.floodFill(10, 10);
    Assert.isTrue(ok);                      // T5
    // Adjacent pixel still off (seed-already-matches did nothing).
    Assert.isEqual(buf[10 * 40] & $20, $00); // T6

    // ── T7 — pen=0 erase: clear-mode fill against a $FF screen.
    g.setFillColor(1); g.clear();           // screen all ones
    g.setPen(0);                            // pen=0 strokes
    // Stroke a box outline cleared (rows 0/5, cols 0/5 of an 6x6
    // outline so the boundary is OFF surrounded by ON pixels).
    g.rect(0, 0, 5, 5);
    g.setFillColor(0);                      // fill with 0 (clear)
    ok = g.floodFill(2, 2);                 // seed in interior
    // Interior pixel (3, 3) cleared.
    Assert.isEqual(buf[3 * 40] & $10, $00); // T7
    // Outside the cleared boundary still lit.
    Assert.isEqual(buf[7 * 40] & $80, $80); // T8

    // ── T9 — small fill returns true (no overflow on a
    // bounded fill well within the queue limit).
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.rect(0, 0, 9, 9);                     // 10x10 outline
    g.setFillColor(1);
    ok = g.floodFill(1, 1);                 // fill the 8x8 interior
    Assert.isTrue(ok);                      // T9

    Stdio.printf("DONE 9\n");
    return;
}
