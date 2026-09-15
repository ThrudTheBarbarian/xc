// subscript_store.xc — coverage for `arr[i] = structValue` writes.
//
// Whole-element struct assignment through a subscript LHS, across
// three struct sizes: small (4 bytes, scalar-return path), medium
// (6 bytes, $B0.. register path) and large (9 bytes, address-
// compute + byte-copy path, including a subscript→subscript copy
// `arr[i] = arr[j]`). The readback fields are printed; they are
// the oracle.

#import "Stdio.xc"

struct Point { u16 x; u16 y; }                             // 4 bytes
struct Header { u8 tag; u16 len; u8 ver; u16 pad; }        // 6 bytes
struct Box { u16 w; u16 h; u16 x; u16 y; u8 tag; }         // 9 bytes

void main(void)
{
    // Small struct (width 4)
    Point* pts = new Point[3];
    Point psrc;
    psrc.x = $1234;
    psrc.y = $5678;
    pts[1] = psrc;
    pts[2] = pts[1];
    Point pA = pts[1];
    Point pB = pts[2];
    Stdio.printf("PA=%u,%u PB=%u,%u\n", pA.x, pA.y, pB.x, pB.y);
    delete pts;

    // Medium struct (width 6)
    Header* hs = new Header[3];
    Header hsrc;
    hsrc.tag = $AA; hsrc.len = $1234; hsrc.ver = $BB; hsrc.pad = $5678;
    hs[0] = hsrc;
    hs[2] = hs[0];
    Header h0 = hs[0];
    Header h2 = hs[2];
    Stdio.printf("H0len=%u H2=%u,%u,%u,%u\n",
                 h0.len, (u16)h2.tag, h2.len, (u16)h2.ver, h2.pad);
    delete hs;

    // Large struct (width 9) — address-compute + byte-copy path.
    Box* bs = new Box[3];
    Box bsrc;
    bsrc.w = 100; bsrc.h = 200; bsrc.x = 1; bsrc.y = 2; bsrc.tag = $F0;
    bs[0] = bsrc;
    bs[2] = bs[0];    // subscript→subscript copy
    Box b0 = bs[0];
    Box b2 = bs[2];
    Stdio.printf("B0w=%u B2=%u,%u,%u,%u,%u\n",
                 b0.w, b2.w, b2.h, b2.x, b2.y, (u16)b2.tag);
    delete bs;
    return;
}
