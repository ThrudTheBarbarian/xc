// subscript_struct.xc — struct-element subscript READ coverage.
//
//   StructT v = arr[i]        (new local from subscript)
//   existingStruct = arr[i]   (assign into existing local)
//
// Small structs (≤8 bytes) go through the $B0.. register
// convention; larger structs go through the address-compute +
// byte-copy helper. Arrays are seeded via subscript field stores
// (endian- and stride-neutral — no raw byte aliasing), then read
// back via struct subscript and printed. The printed fields are the
// oracle.

#import "Stdio.xc"

struct Point { u16 x; u16 y; }                       // 4 bytes
struct Box { u16 w; u16 h; u16 x; u16 y; u8 tag; }   // 9 bytes

void main(void)
{
    // ── Small struct (width 4) ────────────────────────────────
    Point* pts = new Point[3];
    pts[0].x = (u16)10; pts[0].y = (u16)20;
    pts[1].x = (u16)30; pts[1].y = (u16)40;
    pts[2].x = (u16)50; pts[2].y = (u16)60;

    Point p0 = pts[0];
    u8 idx = 2;
    Point p2 = pts[idx];
    Point q;
    q = pts[1];   // existing-struct = subscript

    Stdio.printf("P0=%u,%u P2=%u,%u Q=%u,%u\n",
                 p0.x, p0.y, p2.x, p2.y, q.x, q.y);
    delete pts;

    // ── Large struct (width 9) ─────────────────────────────────
    Box* boxes = new Box[2];
    boxes[0].w = (u16)100; boxes[0].h = (u16)200;
    boxes[0].x = (u16)1;   boxes[0].y = (u16)2;   boxes[0].tag = (u8)$AA;
    boxes[1].w = (u16)300; boxes[1].h = (u16)400;
    boxes[1].x = (u16)3;   boxes[1].y = (u16)4;   boxes[1].tag = (u8)$BB;

    Box b0 = boxes[0];
    Box b1 = boxes[1];
    Stdio.printf("B0=%u,%u,%u,%u,%u B1=%u,%u,%u,%u,%u\n",
                 b0.w, b0.h, b0.x, b0.y, (u16)b0.tag,
                 b1.w, b1.h, b1.x, b1.y, (u16)b1.tag);
    delete boxes;
    return;
}
