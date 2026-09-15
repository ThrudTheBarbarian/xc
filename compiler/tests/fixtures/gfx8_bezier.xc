//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx8_bezier.xc — Gfx8.bezier (quadratic) + Gfx8.bezierTo.
//
// Forward-difference 32-step quadratic walk with line() between
// consecutive samples. The FD math is exact-integer so the final
// sample lands on P2 with no endpoint drift; intermediate sample
// at t=0.5 lands at (P0 + 2*P1 + P2) / 4 (the midpoint formula
// for a quadratic Bezier).
//
// Tests pin:
//   T1-T4   bezier() endpoints + a midpoint pixel + here update
//   T5-T7   bezierTo() picks up `here`, draws to new endpoint,
//           leaves here at the new endpoint for chaining
//   T8-T9   pen=0 erase mode (clear pixels along the curve)

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx8.xc"

void main(void)
{
    Assert.reset();
    u8* buf = new u8[7680];
    Gfx8* g = new Gfx8(buf);
    g.setPen(1);

    // Curve A: P0=(0,0), P1=(32,0), P2=(64,16). The midpoint at
    // t=0.5 is ((0+64+2*32)/4, (0+16+2*0)/4) = (32, 4) — directly
    // computable since B(0.5) = 0.25*P0 + 0.5*P1 + 0.25*P2.
    g.setFillColor(0); g.clear();
    g.bezier(0, 0, 32, 0, 64, 16);

    // Endpoint P0 = (0,0): byte 0 bit 7.
    Assert.isEqual(buf[0]      & $80, $80);              // T1
    // Endpoint P2 = (64,16): row 16, x=64 → byte 8 bit 7.
    Assert.isEqual(buf[16 * 40 + 8] & $80, $80);          // T2
    // Midpoint sample (32, 4): row 4, x=32 → byte 4 bit 7.
    Assert.isEqual(buf[4 * 40 + 4]  & $80, $80);          // T3
    // here should now be at (64, 16).
    Assert.isEqual((u16)g.currentX(), 64);                // T4
    Assert.isEqual((u16)g.currentY(), 16);

    // Curve B: bezierTo() from current here = (64, 16) through
    // control (96, 32) to endpoint (128, 16). Midpoint sample
    // ((64+128+2*96)/4, (16+16+2*32)/4) = (96, 24).
    g.bezierTo(96, 32, 128, 16);
    // Endpoint (128, 16): row 16, x=128 → byte 16 bit 7.
    Assert.isEqual(buf[16 * 40 + 16] & $80, $80);         // T5
    // Midpoint (96, 24): row 24, x=96 → byte 12 bit 7.
    Assert.isEqual(buf[24 * 40 + 12] & $80, $80);         // T6
    // here advanced to (128, 16).
    Assert.isEqual((u16)g.currentX(), 128);               // T7
    Assert.isEqual((u16)g.currentY(), 16);

    // Curve C: pen=0 over $FF clears the curve track. Use the
    // same shape as Curve A.
    g.setFillColor(1); g.clear();
    g.setPen(0);
    g.bezier(0, 0, 32, 0, 64, 16);
    // Endpoint P0 cleared.
    Assert.isEqual(buf[0]           & $80, $00);          // T8
    // Midpoint sample (32, 4) cleared.
    Assert.isEqual(buf[4 * 40 + 4]  & $80, $00);          // T9

    Stdio.printf("DONE 11\n");
    return;
}
