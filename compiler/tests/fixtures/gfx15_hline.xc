//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx15_hline.xc — Gfx15.hline bulk-byte fast path on the
// 2bpp 160×192 GR.15 layout. Mirrors gfx7_hline.xc, with
// y-coordinates spanning the full 192-row screen so the y-table
// path (192 entries, vs Gfx7's 96) is exercised.

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx15.xc"

void main(void)
{
    Assert.reset();

    u8* buf = new u8[7680];
    Gfx15* g = new Gfx15(buf);
    g.setFillColor(0); g.clear();

    // ── Single-byte hline at row 0 ──────────────────────
    g.setPen(2);
    g.hline(4, 6, 0);
    Assert.isEqual((u16)buf[0 * 40 + 1], $A8);            // T1

    // ── Single-byte hline at row 191 (last row, exercises
    //    y > 95 path that Gfx7 can't reach) ──────────────
    g.setFillColor(0); g.clear();
    g.setPen(3);
    g.hline(0, 3, 191);
    Assert.isEqual((u16)buf[191 * 40 + 0], $FF);          // T2

    // ── Full-width hline at row 100 (middle of the screen) ──
    g.setFillColor(0); g.clear();
    g.setPen(3);
    g.hline(0, 159, 100);
    Assert.isEqual((u16)buf[100 * 40 + 0], $FF);          // T3
    Assert.isEqual((u16)buf[100 * 40 + 19], $FF);         // T4
    Assert.isEqual((u16)buf[100 * 40 + 39], $FF);         // T5

    // ── Mid-byte both-ends partial at row 150 ───────────
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.hline(1, 158, 150);
    Assert.isEqual((u16)buf[150 * 40 + 0],  $15);         // T6
    Assert.isEqual((u16)buf[150 * 40 + 1],  $55);         // T7
    Assert.isEqual((u16)buf[150 * 40 + 38], $55);         // T8
    Assert.isEqual((u16)buf[150 * 40 + 39], $54);         // T9

    // ── Off-screen y rejected (y >= 192) ─────────────────
    g.setFillColor(0); g.clear();
    g.setPen(3);
    g.hline(0, 159, 192);                  // T10 — out of bounds
    Assert.isEqual((u16)buf[100 * 40 + 0], $00);
    g.hline(0, 159, -1);                   // T11 — out of bounds
    Assert.isEqual((u16)buf[0 * 40 + 0], $00);

    // ── Negative-x clipping at row 50 ────────────────────
    g.hline(-5, 4, 50);                    // T12 lit pixels 0..4
    Assert.isEqual((u16)buf[50 * 40 + 0], $FF);
    Assert.isEqual((u16)buf[50 * 40 + 1], $C0);

    Stdio.printf("DONE 12\n");
    return;
}
