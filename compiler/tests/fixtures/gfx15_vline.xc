//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx15_vline.xc — Gfx15.vline bulk-byte path. Same shape as
// gfx7_vline (and inheriting the same pen=0-erase fix), with
// y-coordinates that span the full 192-row screen so the
// 192-entry y-table path stays exercised.

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx15.xc"

void main(void)
{
    Assert.reset();

    u8* buf = new u8[7680];
    Gfx15* g = new Gfx15(buf);
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

    // ── Vline that spans the full 192-row screen ────────
    g.setFillColor(0); g.clear();
    g.setPen(3);
    g.vline(0, 0, 191);
    Assert.isEqual((u16)buf[0   * 40 + 0], $C0);           // T5 row 0
    Assert.isEqual((u16)buf[100 * 40 + 0], $C0);           // T6 mid
    Assert.isEqual((u16)buf[191 * 40 + 0], $C0);           // T7 last

    // ── pen=2 over column 5 (pixel 1, non-zero shift) ──
    g.setFillColor(0); g.clear();
    g.setPen(2);
    g.vline(5, 0, 0);
    Assert.isEqual((u16)buf[0 * 40 + 1], $20);             // T8
    g.setPen(1);
    g.vline(5, 0, 0);
    Assert.isEqual((u16)buf[0 * 40 + 1], $10);             // T9 — overwrite

    Stdio.printf("DONE 9\n");
    return;
}
