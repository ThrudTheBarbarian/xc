//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx6_point.xc — Gfx6.plot and Gfx6.getPixel.
//
// Verifies pixel-level bit manipulation: set a pixel at (x, y),
// read it back, clear it with pen=0, verify it's cleared. Also
// checks off-screen bounds and edge pixels.

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx6.xc"

void main(void)
{
    Assert.reset();

    u8* buf = new u8[1920];
    Gfx6* g = new Gfx6(buf);
    g.setFillColor(0); g.clear();

    // ── Plot and read back ────────────────────────────────
    g.setPen(1);
    g.plot(0, 0);
    Assert.isEqual((u16)g.getPixel(0, 0), (u16)1);        // T1
    Assert.isEqual((u16)buf[0], $80);                     // T2: MSB set

    // Plot pixel 7 (LSB) of byte 0.
    g.setFillColor(0); g.clear();
    g.plot(7, 0);
    Assert.isEqual((u16)buf[0], $01);                     // T3
    Assert.isEqual((u16)g.getPixel(7, 0), (u16)1);        // T4

    // Plot pixel at (159, 95) — last pixel of the buffer.
    g.setFillColor(0); g.clear();
    g.plot(159, 95);
    Assert.isEqual((u16)buf[95 * 20 + 19], $01);          // T5
    Assert.isEqual((u16)g.getPixel(159, 95), (u16)1);     // T6

    // ── pen=0 clears pixels ───────────────────────────────
    g.setPen(0);
    g.plot(159, 95);
    Assert.isEqual((u16)buf[95 * 20 + 19], $00);          // T7
    Assert.isEqual((u16)g.getPixel(159, 95), (u16)0);     // T8

    // ── Off-screen plots are no-ops ──────────────────────
    g.setPen(1);
    g.plot(-1, 0);                                         // T9: x < 0
    Assert.isEqual((u16)buf[0], $00);
    g.plot(160, 0);                                        // T10: x >= 160
    Assert.isEqual((u16)buf[0], $00);
    g.plot(0, -1);                                         // T11: y < 0
    Assert.isEqual((u16)buf[0], $00);
    g.plot(0, 96);                                         // T12: y >= 96
    Assert.isEqual((u16)buf[0], $00);

    // ── Off-screen reads return 0 ─────────────────────────
    Assert.isEqual((u16)g.getPixel(-1, 0), (u16)0);       // T13
    Assert.isEqual((u16)g.getPixel(160, 0), (u16)0);      // T14
    Assert.isEqual((u16)g.getPixel(0, -1), (u16)0);       // T15
    Assert.isEqual((u16)g.getPixel(0, 96), (u16)0);       // T16

    Stdio.printf("DONE 16\n");
    return;
}
