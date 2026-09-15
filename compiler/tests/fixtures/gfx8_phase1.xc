//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx8_phase1.xc — Gfx/Gfx8 phase 1: state + plot + getPixel + hline.
//
// Allocates a 7680-byte heap buffer to stand in for GR.8 screen
// RAM, constructs Gfx8 against that buffer, then exercises:
//   - clear() with both fillColor=0 and fillColor=1
//   - plot() at known coordinates and getPixel() round-trip
//   - off-screen plot() ignored, off-screen getPixel() returns 0
//   - hline() — phase-1 per-pixel implementation; bulk-byte
//     fast path lands in phase 2 alongside line/rect work.
//
// Verifies the byte-level layout: a plot at (8, 0) with color=1
// must light bit 7 of buffer[1] (= $80), since byte offset
// = (0*40) + (8>>3) = 1 and bit_index = 8 & 7 = 0. Several
// distinct (x, y) pairs cross-check the row-table arithmetic.

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx8.xc"

void main(void)
{
    Assert.reset();

    u8* buf = new u8[7680];
    Gfx8* g = new Gfx8(buf);

    // T1-T2: clear to 0, verify a sample byte is 0.
    g.setFillColor(0);
    g.clear();
    Assert.isEqual(buf[0], 0);
    Assert.isEqual(buf[7679], 0);

    // T3-T5: clear to 1 (all $FF), verify.
    g.setFillColor(1);
    g.clear();
    Assert.isEqual(buf[0], $FF);
    Assert.isEqual(buf[3840], $FF);
    Assert.isEqual(buf[7679], $FF);

    // T6-T9: plot a few pixels with pen=1 onto a cleared
    // buffer and verify the exact byte/bit pattern.
    g.setFillColor(0);
    g.clear();
    g.setPen(1);
    g.plot(0, 0);
    g.plot(7, 0);
    g.plot(8, 0);
    g.plot(319, 0);
    g.plot(0, 191);

    Assert.isEqual(buf[0], $81);    // bits 7 and 0 both set
    Assert.isEqual(buf[1], $80);
    Assert.isEqual(buf[39], $01);
    Assert.isEqual(buf[7640], $80);

    // T10-T15: getPixel round-trip.
    Assert.isEqual(g.getPixel(0, 0), 1);
    Assert.isEqual(g.getPixel(1, 0), 0);
    Assert.isEqual(g.getPixel(7, 0), 1);
    Assert.isEqual(g.getPixel(8, 0), 1);
    Assert.isEqual(g.getPixel(319, 0), 1);
    Assert.isEqual(g.getPixel(0, 191), 1);

    // T16-T17: clear-then-plot at color=0 over a $FF background.
    g.setFillColor(1);
    g.clear();
    g.setPen(0);
    g.plot(0, 0);
    g.plot(15, 0);
    Assert.isEqual(buf[0], $7F);
    Assert.isEqual(buf[1], $FE);

    // T18-T19: out-of-range plots are no-ops.
    g.setFillColor(0);
    g.clear();
    g.setPen(1);
    g.plot(-1, 0);
    g.plot(320, 0);
    g.plot(0, -1);
    g.plot(0, 192);
    Assert.isEqual(buf[0], 0);
    Assert.isEqual(buf[7679], 0);

    // T20-T22: out-of-range getPixel returns 0 without faulting.
    Assert.isEqual(g.getPixel(-1, 0), 0);
    Assert.isEqual(g.getPixel(320, 0), 0);
    Assert.isEqual(g.getPixel(0, 192), 0);

    // T23-T24: hline. 10-pixel run from x=5 to x=14 on row 1.
    // x=5..7 spans byte 0 (offset 40) bits 2/1/0 → $07.
    // x=8..14 spans byte 1 (offset 41) bits 7..1 → $FE.
    g.clear();
    g.setPen(1);
    g.hline(5, 14, 1);
    Assert.isEqual(buf[40], $07);
    Assert.isEqual(buf[41], $FE);

    Assert.summary();
    return;
}
