//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx6_hline.xc — Gfx6.hline bulk-byte fast path.
//
// Verifies the GR.6 (160×96 2-colour, 1bpp) horizontal-line routine
// against an off-screen buffer for every interesting endpoint
// alignment: single-byte, byte-aligned multi-byte, mid-byte partial
// endpoints, and full-width spans. Also exercises pen=0 (clear) mode.
//
// Layout: each row is 20 bytes (160 px / 8 pixels per byte), each
// byte holds 8 pixels (1 bit each). Pixel 0 is MSB ($80), pixel 7 is
// LSB ($01). A byte with all 8 pixels set = $FF.

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx6.xc"

void main(void)
{
    Assert.reset();

    u8* buf = new u8[1920];
    Gfx6* g = new Gfx6(buf);
    g.setFillColor(0); g.clear();

    // ── Single-byte hline ─────────────────────────────────
    // (0..7, 0) at pen=1 fills the first byte of row 0 entirely.
    // byteL=0, byteR=0, iL=0, iR=7 → single-byte path.
    // mask = hLeftSet[0] & hRightSet[7] = $FF & $FF = $FF.
    g.setPen(1);
    g.hline(0, 7, 0);
    Assert.isEqual((u16)buf[0], $FF);                    // T1

    // Clear the same byte with pen=0.
    g.setPen(0);
    g.hline(0, 7, 0);
    Assert.isEqual((u16)buf[0], $00);                    // T2

    // ── Mid-byte partial span ─────────────────────────────
    // (2..5, 0) at pen=1: pixels 2,3,4,5 = $20|$10|$08|$04 = $3C.
    g.setPen(1);
    g.hline(2, 5, 0);
    Assert.isEqual((u16)buf[0], $3C);                    // T3

    // Single pixel at pixel 3.
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.hline(3, 3, 0);
    Assert.isEqual((u16)buf[0], $10);                    // T4

    // ── Full-width byte-aligned hline ─────────────────────
    // (0..159, 1) at pen=1 fills all 20 bytes of row 1 to $FF.
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.hline(0, 159, 1);
    Assert.isEqual((u16)buf[1 * 20 + 0],  $FF);          // T5
    Assert.isEqual((u16)buf[1 * 20 + 10], $FF);          // T6
    Assert.isEqual((u16)buf[1 * 20 + 19], $FF);          // T7

    // ── Multi-byte with partial edges ─────────────────────
    // (1..158, 2) at pen=1.
    //   byteL=0, iL=1, byteR=19, iR=6.
    //   left partial: buf[2*20+0] = hLeftSet[1] = $7F
    //   middle: bytes 1..18 = $FF
    //   right partial: buf[2*20+19] = hRightSet[6] = $FE
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.hline(1, 158, 2);
    Assert.isEqual((u16)buf[2 * 20 + 0],  $7F);          // T8
    Assert.isEqual((u16)buf[2 * 20 + 1],  $FF);          // T9
    Assert.isEqual((u16)buf[2 * 20 + 18], $FF);          // T10
    Assert.isEqual((u16)buf[2 * 20 + 19], $FE);          // T11

    // ── Two-byte boundary crossing ────────────────────────
    // (7..8, 3) at pen=1. byteL=0, iL=7, byteR=1, iR=0.
    //   buf[3*20+0] = old | hLeftSet[7] = $01
    //   buf[3*20+1] = old | hRightSet[0] = $80
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.hline(7, 8, 3);
    Assert.isEqual((u16)buf[3 * 20 + 0], $01);           // T12
    Assert.isEqual((u16)buf[3 * 20 + 1], $80);           // T13

    // ── pen=0 clear over previously set span ──────────────
    // Clear pixels 4..7 of row 3, byte 0, leaving pixels 0..3.
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.hline(0, 7, 4);               // fill byte to $FF
    g.setPen(0);
    g.hline(4, 7, 4);               // clear low nibble → $F0
    Assert.isEqual((u16)buf[4 * 20 + 0], $F0);           // T14

    // ── Off-screen / clipped hlines must not corrupt RAM ──
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.hline(-50, -1, 5);            // T15: fully left of screen
    Assert.isEqual((u16)buf[5 * 20 + 0], $00);           // unchanged
    g.hline(160, 250, 6);           // T16: fully right of screen
    Assert.isEqual((u16)buf[6 * 20 + 19], $00);          // unchanged
    g.hline(0, 159, -1);            // T17: y < 0
    g.hline(0, 159, 96);            // T18: y >= 96
    Assert.isEqual((u16)buf[0], $00);
    Assert.isEqual((u16)buf[1919], $00);
    // Negative-x clipping: (-5, 4, 7) → lo=0, hi=4.
    // Pixels 0..4 of row 7 = $80|$40|$20|$10|$08 = $F8.
    g.hline(-5, 4, 7);              // T19
    Assert.isEqual((u16)buf[7 * 20 + 0], $F8);           // bits 0..4 set

    // ── Reversed endpoints (lo > hi) ──────────────────────
    // hline(5, 2, 8) should be equivalent to hline(2, 5, 8).
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.hline(5, 2, 8);
    Assert.isEqual((u16)buf[8 * 20 + 0], $3C);           // T20: same as (2,5)

    Stdio.printf("DONE 20\n");
    return;
}
