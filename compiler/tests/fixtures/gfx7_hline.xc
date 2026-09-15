//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx7_hline.xc — Gfx7.hline bulk-byte fast path.
//
// Verifies the GR.7 (160×96 4-colour) horizontal-line routine
// against an off-screen buffer for every interesting endpoint
// alignment: single-byte, byte-aligned multi-byte, mid-byte
// partial endpoints, and full-width spans. Also exercises every
// pen colour 0..3 so the fill-byte replication ($00/$55/$AA/$FF)
// and the partial-byte AND/OR mask machinery are both covered.
//
// Layout reminder: each row is 40 bytes (160 px / 4 pixels per
// byte), each byte holds 4 pixels (2 bits each). Pixel p in a
// byte sits at bit positions (6 - p*2) .. (7 - p*2); pixel 0 is
// the high pair, pixel 3 the low pair.

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx7.xc"

void main(void)
{
    Assert.reset();

    u8* buf = new u8[3840];
    Gfx7* g = new Gfx7(buf);
    g.setFillColor(0); g.clear();

    // ── Single-byte hline ─────────────────────────────────
    // (4..6, 30) at pen=2 hits pixels 4..6 of row 30 = byte 1
    // of row 30, pixels 0..2 (since 4>>2 = 1, 4&3 = 0; 6&3 = 2).
    // Byte 30*40 + 1 = 1201. Mask = partLeft[0] AND partRight[2]
    // = $FF AND $FC = $FC. Fill colour 2 → $AA. Touched bits =
    // $AA AND $FC = $A8. Untouched bits = old AND $03 = 0.
    // Expected: buf[1201] = $A8.
    g.setPen(2);
    g.hline(4, 6, 30);
    Assert.isEqual((u16)buf[1201], $A8);                 // T1

    // Single-byte clear of two of the three pixels with pen=0.
    // (4..5, 30) at pen=0: mask = $FF AND $F0 = $F0. Clear
    // bits = $0F. Old byte $A8 → ($A8 AND $0F) | ($00 AND $F0)
    // = $08 (only pixel 2 of the original three remains lit).
    g.setPen(0);
    g.hline(4, 5, 30);
    Assert.isEqual((u16)buf[1201], $08);                 // T2

    // ── Byte-aligned full-width hline ─────────────────────
    // (0..159, 31) at pen=3 fills the entire row to $FF. byteL
    // = 0, byteR = 39, iL = 0, iR = 3 → multi-byte path with no
    // edge effect; partLeft[0] = $FF, partRight[3] = $FF.
    g.setPen(3);
    g.hline(0, 159, 31);
    Assert.isEqual((u16)buf[31 * 40 + 0], $FF);          // T3
    Assert.isEqual((u16)buf[31 * 40 + 19], $FF);         // T4
    Assert.isEqual((u16)buf[31 * 40 + 39], $FF);         // T5

    // ── Mid-byte both-ends partial ────────────────────────
    // (1..158, 32) at pen=1 ($55 fill). lo=1, hi=158 → byteL=0,
    // iL=1, byteR=39, iR=2.
    //   left partial:  buf[32*40+0] = (0 & clrLeft[1])
    //                                | ($55 & partLeft[1])
    //                = (0 & $C0) | ($55 & $3F) = $15
    //   middle bytes 32*40+1 .. 32*40+38 = $55 each
    //   right partial: buf[32*40+39] = (0 & clrRight[2])
    //                                | ($55 & partRight[2])
    //                = (0 & $03) | ($55 & $FC) = $54
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.hline(1, 158, 32);
    Assert.isEqual((u16)buf[32 * 40 + 0],  $15);         // T6
    Assert.isEqual((u16)buf[32 * 40 + 1],  $55);         // T7
    Assert.isEqual((u16)buf[32 * 40 + 38], $55);         // T8
    Assert.isEqual((u16)buf[32 * 40 + 39], $54);         // T9

    // ── Two-byte hline crossing exactly one boundary ──────
    // (3..4, 33) at pen=3. Pixels 3 of byte 0 and pixel 0 of
    // byte 1. left mask = partLeft[3] = $03; right mask =
    // partRight[0] = $C0.
    //   buf[33*40+0] = old & clrLeft[3]  | $FF & $03 = $03
    //   buf[33*40+1] = old & clrRight[0] | $FF & $C0 = $C0
    g.setFillColor(0); g.clear();
    g.setPen(3);
    g.hline(3, 4, 33);
    Assert.isEqual((u16)buf[33 * 40 + 0], $03);          // T10
    Assert.isEqual((u16)buf[33 * 40 + 1], $C0);          // T11

    // ── Single-byte at every pixel position ───────────────
    // (8, 34) at pen=1: byte 2, pixel 0 → bits $40 in $55 fill.
    g.setFillColor(0); g.clear();
    g.setPen(1);
    g.hline(8, 8, 34);
    Assert.isEqual((u16)buf[34 * 40 + 2], $40);          // T12

    // (9, 34) at pen=2: byte 2, pixel 1 → ($AA & $30) = $20.
    // T12 left pixel 0 at colour 1 ($40); pixel 1 picks up $20.
    g.setPen(2);
    g.hline(9, 9, 34);
    Assert.isEqual((u16)buf[34 * 40 + 2], $60);          // T13 ($40 | $20)

    // (10, 34) at pen=3: byte 2, pixel 2 → ($FF & $0C) = $0C.
    g.setPen(3);
    g.hline(10, 10, 34);
    Assert.isEqual((u16)buf[34 * 40 + 2], $6C);          // T14

    // (11, 34) at pen=1: byte 2, pixel 3 → ($55 & $03) = $01.
    g.setPen(1);
    g.hline(11, 11, 34);
    Assert.isEqual((u16)buf[34 * 40 + 2], $6D);          // T15

    // ── Off-screen / clipped hlines must not corrupt RAM ──
    g.setFillColor(0); g.clear();
    g.setPen(3);
    g.hline(-50, -1, 35);                       // T16: fully left of screen
    Assert.isEqual((u16)buf[35 * 40 + 0], $00);          // unchanged
    g.hline(160, 250, 36);                      // T17: fully right of screen
    Assert.isEqual((u16)buf[36 * 40 + 39], $00);         // unchanged
    g.hline(0, 159, -1);                        // T18: y < 0
    g.hline(0, 159, 96);                        // T19: y >= 96
    Assert.isEqual((u16)buf[0], $00);
    Assert.isEqual((u16)buf[3839], $00);
    // Negative-x clipping: (-5, 4, 37) should fill pixels 0..4.
    g.hline(-5, 4, 37);                         // T20
    Assert.isEqual((u16)buf[37 * 40 + 0], $FF);          // pixels 0..3 lit
    Assert.isEqual((u16)buf[37 * 40 + 1], $C0);          // pixel 0 lit

    Stdio.printf("DONE 20\n");
    return;
}
