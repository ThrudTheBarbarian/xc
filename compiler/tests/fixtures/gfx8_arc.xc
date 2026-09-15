//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx8_arc.xc — Gfx8.arc partial-circle outline.
//
// quadrants bitmask: $01 NE, $02 NW, $04 SW, $08 SE. 0 = no
// draw, $0F = full circle. Each iter of the Bresenham trace
// emits only the reflections in the requested quadrants.
//
// Atari y is screen-down: "north" quadrants are at cy-y
// (above centre), "south" at cy+y (below).

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx8.xc"

void main(void)
{
    Assert.reset();
    u8* buf = new u8[7680];
    Gfx8* g = new Gfx8(buf);
    g.setPen(1);

    // ── r=0 plots the centre regardless of mask -----------
    g.setFillColor(0); g.clear();
    g.arc(40, 30, 0, $01);
    Assert.isEqual(buf[30 * 40 + 5] & $80, $80);  // T1

    // ── quadrants=0 is a no-op --------------------------
    g.clear();
    g.arc(40, 30, 5, 0);
    Assert.isEqual(buf[30 * 40 + 5], $00);        // T2 centre untouched
    Assert.isEqual(buf[25 * 40 + 5], $00);        // T3 above untouched

    // ── r=2 NE only ($01) ------------------------------
    // Pixels in NE quadrant: (cx+x, cy-y) and (cx+y, cy-x)
    // for the Bresenham steps (x=0,y=2) (x=1,y=2) (x=2,y=2)
    // -> (cx+0,cy-2), (cx+2,cy-0); (cx+1,cy-2), (cx+2,cy-1);
    //    (cx+2,cy-2), (cx+2,cy-2 dup).
    // Centre (40, 30): expected lit pixels (40,28), (42,30),
    // (41,28), (42,29), (42,28).
    g.clear();
    g.arc(40, 30, 2, $01);
    Assert.isEqual(buf[28 * 40 + 5] & $80, $80);  // T4 (40,28)
    Assert.isEqual(buf[30 * 40 + 5] & $20, $20);  // T5 (42,30) — bit5 of byte 5
    Assert.isEqual(buf[28 * 40 + 5] & $40, $40);  // T6 (41,28)
    // SW reflection (38,32) must NOT be lit (we only asked
    // for NE).
    Assert.isEqual(buf[32 * 40 + 4] & $04, $00);  // T7

    // ── full circle via $0F matches circle() -----------
    g.clear();
    g.arc(40, 30, 5, $0F);
    // Top (40, 25), bottom (40, 35), left (35, 30), right (45, 30)
    Assert.isEqual(buf[25 * 40 + 5] & $80, $80);  // T8 top
    Assert.isEqual(buf[35 * 40 + 5] & $80, $80);  // T9 bottom
    // (35,30): byte 30*40+4=1204, mask $80>>3 = $10
    Assert.isEqual(buf[30 * 40 + 4] & $10, $10);  // T10 left (35,30)
    // (45,30): byte 30*40+5=1205, mask $80>>5 = $04
    Assert.isEqual(buf[30 * 40 + 5] & $04, $04);  // T11 right (45,30)

    // ── two adjacent quadrants (NE+SE = right half) ----
    // Right half = $01 | $08 = $09. Top and bottom plot in
    // each respective quadrant; left side does NOT.
    g.clear();
    g.arc(40, 30, 5, $09);
    // (40, 25) belongs to BOTH NE and NW (it's on the axis).
    // Our quadrant-mask convention: axial points are emitted
    // when EITHER adjacent quadrant is requested. The Bresenham
    // step (x=0, y=5) emits (cx+0, cy-5) for NE and (cx-0, cy-5)
    // for NW — same point. With NE set, it lights.
    Assert.isEqual(buf[25 * 40 + 5] & $80, $80);  // T12 (40,25) NE-axial
    Assert.isEqual(buf[35 * 40 + 5] & $80, $80);  // T13 (40,35) SE-axial
    Assert.isEqual(buf[30 * 40 + 5] & $04, $04);  // T14 right (45,30)
    // Left side (35,30) NOT lit (NW + SW are masked off).
    Assert.isEqual(buf[30 * 40 + 4] & $10, $00);  // T15 left untouched

    // ── pen=0 erases through arc ----------------------
    g.setFillColor(1); g.clear();   // all $FF
    g.setPen(0);
    g.arc(40, 30, 2, $0F);          // full mini circle
    // Top pixel (40,28) cleared.
    Assert.isEqual(buf[28 * 40 + 5] & $80, $00);  // T16 top erased
    Assert.isEqual(buf[32 * 40 + 5] & $80, $00);  // T17 bottom erased
    // Far-away byte still $FF.
    Assert.isEqual(buf[100 * 40 + 5], $FF);       // T18 untouched

    // ── fillArc: full disk (quadrants = $0F) ----------
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.fillArc(40, 30, 3, $0F);
    // Centre lit
    Assert.isEqual(buf[30 * 40 + 5] & $80, $80);  // T19 centre
    // Top of disk (40, 27) lit
    Assert.isEqual(buf[27 * 40 + 5] & $80, $80);  // T20 top
    // Right edge (43, 30): byte 5, bit $80>>3=$10
    Assert.isEqual(buf[30 * 40 + 5] & $10, $10);  // T21 right

    // ── fillArc: NE only ----------------------------
    // Right half above centre row. (40, 27), (41, 28),
    // (42, 28) etc. lit. Below-centre rows untouched.
    g.clear();
    g.fillArc(40, 30, 3, $01);
    Assert.isEqual(buf[27 * 40 + 5] & $80, $80);  // T22 top (40,27) NE
    // Centre row (40, 30): NE includes the row at +0
    // offset? wide-row at cy+x with x=0 is the centre row.
    // SE is the lower half (cx to cx+y), NE is the upper.
    // NE only -> centre row right half NOT lit (centre row
    // is x=0, which only goes through SE/SW gates).
    Assert.isEqual(buf[30 * 40 + 5] & $10, $00);  // T23 right (43,30) NOT
    // Below centre (32, 30): not in NE
    Assert.isEqual(buf[31 * 40 + 5] & $80, $00);  // T24 below

    // ── fillArc: SE only — right half below centre ----
    g.clear();
    g.fillArc(40, 30, 3, $08);
    Assert.isEqual(buf[33 * 40 + 5] & $80, $80);  // T25 bottom (40,33)
    Assert.isEqual(buf[30 * 40 + 5] & $10, $10);  // T26 right (43,30) SE
    Assert.isEqual(buf[27 * 40 + 5] & $80, $00);  // T27 top NOT lit

    Stdio.printf("DONE 27\n");
    return;
}
