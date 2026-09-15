//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx7_vline.xc — Gfx7.vline at every pen colour, including the
// pen=0 erase path that the prior bulk-byte body silently no-op'd
// (orMask = col << shift = 0 when col is 0, so the loop body's
// pure ORA never cleared a previously-lit slot). Fixed by adding
// an AND-with-inverted-field-mask before the OR.

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx7.xc"

void main(void)
{
    Assert.reset();

    u8* buf = new u8[3840];
    Gfx7* g = new Gfx7(buf);
    g.setFillColor(0); g.clear();

    // ── Vline at colour 3, column 4 (byte 1, pixel 0) ────
    g.setPen(3);
    g.vline(4, 0, 5);
    Assert.isEqual((u16)buf[0 * 40 + 1], $C0);             // T1
    Assert.isEqual((u16)buf[5 * 40 + 1], $C0);             // T2

    // ── pen=0 vline same column erases ──────────────────
    g.setPen(0);
    g.vline(4, 0, 5);
    Assert.isEqual((u16)buf[0 * 40 + 1], $00);             // T3
    Assert.isEqual((u16)buf[5 * 40 + 1], $00);             // T4

    // ── pen=2 vline at column 5 (pixel 1) — 2-bit field
    //    update at a non-zero shift position ──────────────
    g.setFillColor(0); g.clear();
    g.setPen(2);
    g.vline(5, 0, 0);
    Assert.isEqual((u16)buf[0 * 40 + 1], $20);             // T5

    // ── pen=1 over the colour-2 column should overwrite,
    //    not OR (would leave $30 = colour 3 in the slot) ──
    g.setPen(1);
    g.vline(5, 0, 0);
    Assert.isEqual((u16)buf[0 * 40 + 1], $10);             // T6

    // ── Off-screen / clipped / swapped y0 > y1 ────────────
    g.setFillColor(0); g.clear();
    g.setPen(3);
    g.vline(-1, 0, 5);                  // T7: x < 0 — no-op
    Assert.isEqual((u16)buf[0 * 40 + 0], $00);
    g.vline(160, 0, 5);                 // T8: x >= 160 — no-op
    Assert.isEqual((u16)buf[0 * 40 + 39], $00);
    g.vline(0, 95, 0);                  // T9: y0 > y1 — auto-swap
    Assert.isEqual((u16)buf[0 * 40 + 0], $C0);
    Assert.isEqual((u16)buf[95 * 40 + 0], $C0);

    Stdio.printf("DONE 9\n");
    return;
}
