//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx6_vline.xc — Gfx6.vline at pen=0 and pen=1.
//
// Verifies the GR.6 (160×96 2-colour, 1bpp) vertical-line routine.
// Each row advances by 20 bytes; the bit mask stays constant within
// a column. pen=1 ORs the mask in; pen=0 ANDs the inverted mask.
// pen=0 must actually erase (unlike the original Gfx7 draft that
// was pure-OR and silently no-op'd for pen=0).

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx6.xc"

void main(void)
{
    Assert.reset();

    u8* buf = new u8[1920];
    Gfx6* g = new Gfx6(buf);
    g.setFillColor(0); g.clear();

    // ── Vline at pen=1, column 0 (MSB of byte 0) ──────────
    g.setPen(1);
    g.vline(0, 0, 5);
    Assert.isEqual((u16)buf[0 * 20 + 0], $80);            // T1: row 0
    Assert.isEqual((u16)buf[5 * 20 + 0], $80);            // T2: row 5

    // ── pen=0 vline same column erases ────────────────────
    g.setPen(0);
    g.vline(0, 0, 5);
    Assert.isEqual((u16)buf[0 * 20 + 0], $00);            // T3
    Assert.isEqual((u16)buf[5 * 20 + 0], $00);            // T4

    // ── pen=1 at column 7 (LSB, mask=$01) ────────────────
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.vline(7, 0, 0);
    Assert.isEqual((u16)buf[0 * 20 + 0], $01);            // T5

    // ── pen=0 overwrites a previously set pixel ──────────
    // pen=0 must clear the bit, not leave it set.
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.vline(3, 0, 0);                // set pixel 3 → $10
    g.setPen(2);                     // pen > 1 should clamp to 1
    g.vline(3, 0, 0);                // should set again (pen != 0)
    Assert.isEqual((u16)buf[0 * 20 + 0], $10);            // T6
    g.setPen(0);
    g.vline(3, 0, 0);                // clear pixel 3
    Assert.isEqual((u16)buf[0 * 20 + 0], $00);            // T7

    // ── Off-screen / clipped / swapped y0 > y1 ────────────
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.vline(-1, 0, 5);               // T8: x < 0 — no-op
    Assert.isEqual((u16)buf[0], $00);
    g.vline(160, 0, 5);              // T9: x >= 160 — no-op
    Assert.isEqual((u16)buf[0], $00);
    g.vline(0, 95, 0);               // T10: y0 > y1 — auto-swap
    Assert.isEqual((u16)buf[0 * 20 + 0], $80);
    Assert.isEqual((u16)buf[95 * 20 + 0], $80);

    Stdio.printf("DONE 10\n");
    return;
}
