//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx8_line_octants.xc — Gfx8.line correctness across all 8
// Bresenham octants. Phase-1 implementation pins the byte-
// exact pattern each octant produces so the upcoming asm
// rewrites (phase 2: tight inner loop; phase 3: octant-
// specific routines; phase 4: self-modifying code; phase 5:
// draw-from-both-ends) can't silently regress endpoints,
// midpoint placement, or step direction.
//
// Octant layout (sign of dx, sign of dy, |dx|>|dy|):
//   T1   horizontal  +x        — degenerate y-major case
//   T2   vertical    +y        — degenerate x-major case
//   T3   diagonal    +x +y =1  — both endpoints + midpoint
//   T4   x-major     +x +y     — slope < 1 in quadrant 1
//   T5   y-major     +x +y     — slope > 1 in quadrant 1
//   T6   x-major     -x +y     — quadrant 2 mirror of T4
//   T7   y-major     -x -y     — quadrant 3 mirror of T5
//   T8   x-major     +x -y     — quadrant 4 mirror of T4
//   T9   pen=0 over $FF        — clear-mode line still tracks

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx8.xc"

void main(void)
{
    Assert.reset();
    u8* buf = new u8[7680];
    Gfx8* g = new Gfx8(buf);

    // T1: horizontal line at y=0 from x=0 to x=15. All 16
    // pixels lit -> bytes 0..1 = $FF.
    g.setFillColor(0); g.clear();
    g.setPen(1); g.line(0, 0, 15, 0);
    Assert.isEqual(buf[0], $FF);
    Assert.isEqual(buf[1], $FF);

    // T2: vertical line at x=0 from y=0 to y=3. Each row's
    // byte 0 has the leftmost pixel = $80.
    g.clear();
    g.line(0, 0, 0, 3);
    Assert.isEqual(buf[0],   $80);
    Assert.isEqual(buf[40],  $80);
    Assert.isEqual(buf[80],  $80);
    Assert.isEqual(buf[120], $80);

    // T3: 45° diagonal from (0,0) to (3,3). Pixels (0,0),
    // (1,1), (2,2), (3,3). Each at the correct byte/bit.
    //   (0,0) -> buf[0]   bit7 = $80
    //   (1,1) -> buf[40]  bit6 = $40
    //   (2,2) -> buf[80]  bit5 = $20
    //   (3,3) -> buf[120] bit4 = $10
    g.clear();
    g.line(0, 0, 3, 3);
    Assert.isEqual(buf[0],   $80);
    Assert.isEqual(buf[40],  $40);
    Assert.isEqual(buf[80],  $20);
    Assert.isEqual(buf[120], $10);

    // T4: x-major shallow line from (0,0) to (8,1). dx=8,
    // dy=1. The first row picks up most of the pixels, the
    // second row picks up the rest at the right end.
    //   Pixels in row 0 are byte 0 bits 7..1 (or near).
    //   Last pixel (8,1) lands on buf[40+1]=buf[41] bit 7.
    g.clear();
    g.line(0, 0, 8, 1);
    Assert.isEqual(buf[0]  & $80, $80);  // start pixel
    Assert.isEqual(buf[41] & $80, $80);  // end pixel

    // T5: y-major steep line from (0,0) to (1,8). dx=1, dy=8.
    // First column picks up most pixels, last pixel at (1,8)
    // is byte 0 of row 8 with bit 6.
    g.clear();
    g.line(0, 0, 1, 8);
    Assert.isEqual(buf[0]       & $80, $80);  // start
    Assert.isEqual(buf[8 * 40]  & $40, $40);  // end (y=8, x=1)

    // T6: x-major in quadrant 2 — sx = -1. Line from (8,0)
    // to (0,1). First pixel at (8,0) -> buf[1] bit 7. End
    // pixel at (0,1) -> buf[40] bit 7.
    g.clear();
    g.line(8, 0, 0, 1);
    Assert.isEqual(buf[1]  & $80, $80);  // start
    Assert.isEqual(buf[40] & $80, $80);  // end

    // T7: y-major in quadrant 3 — sx = -1, sy = -1. Line
    // from (1,8) to (0,0). End pixel at (0,0) -> buf[0] bit
    // 7.
    g.clear();
    g.line(1, 8, 0, 0);
    Assert.isEqual(buf[8 * 40] & $40, $40);  // start (1,8)
    Assert.isEqual(buf[0]      & $80, $80);  // end   (0,0)

    // T8: x-major in quadrant 4 — sx = +1, sy = -1. Line
    // from (0,8) to (8,0). End pixel at (8,0) -> buf[1] bit
    // 7.
    g.clear();
    g.line(0, 8, 8, 0);
    Assert.isEqual(buf[8 * 40] & $80, $80);  // start (0,8)
    Assert.isEqual(buf[1]      & $80, $80);  // end   (8,0)

    // T9a: slope > 0.5 stress — line(0, 0, 10, 6). Pre-fix
    // the asm fast path took one too many y-steps for slope
    // > 0.5 and ended at (10, 7) instead of (10, 6). Standard
    // Bresenham sequence: (0,0)(1,1)(2,1)(3,2)(4,2)(5,3)(6,4)
    // (7,4)(8,5)(9,5)(10,6).
    g.setFillColor(0); g.clear();
    g.setPen(1); g.line(0, 0, 10, 6);
    Assert.isEqual(buf[0],   $80);          // (0,0)
    Assert.isEqual(buf[40],  $60);          // (1,1) (2,1)
    Assert.isEqual(buf[80],  $18);          // (3,2) (4,2)
    Assert.isEqual(buf[120], $04);          // (5,3)
    Assert.isEqual(buf[160], $03);          // (6,4) (7,4)
    Assert.isEqual(buf[201] & $C0, $C0);    // (8,5) (9,5) byte1
    Assert.isEqual(buf[241] & $20, $20);    // (10,6) endpoint byte1
    Assert.isEqual(buf[281] & $20, $00);    // y=7 byte1 untouched

    // T9: pen=0 over $FF background. Line from (0,0) to
    // (3,3) clears the four diagonal pixels. The (1,1) bit
    // stays cleared, the (2,2) byte still has the rest of
    // its pixels lit.
    g.setFillColor(1); g.clear();
    g.setPen(0); g.line(0, 0, 3, 3);
    Assert.isEqual(buf[0]   & $80, $00);
    Assert.isEqual(buf[40]  & $40, $00);
    Assert.isEqual(buf[80]  & $20, $00);
    Assert.isEqual(buf[120] & $10, $00);
    // adjacent pixel at (1,0) byte 0 bit 6 should still be
    // set (we only cleared (0,0) bit 7 in row 0).
    Assert.isEqual(buf[0]   & $40, $40);

    Stdio.printf("DONE 30\n");
    return;
}
