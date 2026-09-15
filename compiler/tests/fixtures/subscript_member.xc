// subscript_member.xc — coverage for `arr[i].field = val` writes.
//
// The LHS is a member access whose BASE is itself a subscript.
// Field widths 1 and 2, const and dynamic index. Values are
// written through the subscript-member LHS, read back via a full
// struct subscript, and printed. The printed fields are the
// oracle.

#import "Stdio.xc"

struct Point { u16 x; u16 y; }             // 4 bytes, u16 fields
struct Header { u8 tag; u16 len; u8 ver; } // 4 bytes, mixed widths

void main(void)
{
    Point* pts = new Point[4];
    pts[0].x = 10;       pts[0].y = 20;
    pts[1].x = 30;       pts[1].y = 40;
    u8 i = 2;
    pts[i].x = 50;       pts[i].y = 60;
    pts[3].x = $FEDC;    pts[3].y = $BA98;

    Point p0 = pts[0];
    Point p1 = pts[1];
    Point p2 = pts[i];
    Point p3 = pts[3];

    Stdio.printf("P0=%u,%u P1=%u,%u P2=%u,%u P3=%u,%u\n",
                 p0.x, p0.y, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y);

    delete pts;

    // Mixed-width fields
    Header* hs = new Header[2];
    hs[0].tag = $AA;
    hs[0].len = $1234;
    hs[0].ver = $01;
    u8 j = 1;
    hs[j].tag = $BB;
    hs[j].len = $5678;
    hs[j].ver = $02;

    Header h0 = hs[0];
    Header h1 = hs[j];

    Stdio.printf("H0=%u,%u,%u H1=%u,%u,%u\n",
                 (u16)h0.tag, h0.len, (u16)h0.ver,
                 (u16)h1.tag, h1.len, (u16)h1.ver);

    delete hs;
    return;
}
