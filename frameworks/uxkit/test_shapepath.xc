// test_shapepath.xc — UXShapePath bounding box + even-odd point containment.
#import <Stdio.xc>
#import "UXShapePath.xc"
#import "UXGeometry.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }
i32 inside(UXShapePath* p, i16 x, i16 y)
    {
    return p.containsPoint(x, y) ? (i32)1 : (i32)0;
    }

void main(void)
    {
    gFails = (i32)0;

    // a square 0,0..100,100
    UXShapePath* sq = UXShapePath.rect((i16)0, (i16)0, (i16)100, (i16)100);
    UXRect bb = sq.boundingBox();
    check("bbox x", (i32)bb.x, (i32)0);
    check("bbox w", (i32)bb.w, (i32)100);
    check("bbox h", (i32)bb.h, (i32)100);
    check("centre inside", inside(sq, (i16)50, (i16)50), (i32)1);
    check("right of it outside", inside(sq, (i16)150, (i16)50), (i32)0);
    check("left of it outside", inside(sq, (i16)-10, (i16)50), (i32)0);
    check("below it outside", inside(sq, (i16)50, (i16)150), (i32)0);
    check("near a corner inside", inside(sq, (i16)5, (i16)5), (i32)1);

    // a triangle (0,0)-(100,0)-(50,100)
    UXShapePath* tri = new UXShapePath();
    tri.moveTo((i16)0, (i16)0);
    tri.lineTo((i16)100, (i16)0);
    tri.lineTo((i16)50, (i16)100);
    tri.close();
    check("triangle interior", inside(tri, (i16)50, (i16)30), (i32)1);
    check("triangle apex region", inside(tri, (i16)50, (i16)10), (i32)1);
    check("triangle bottom-left outside", inside(tri, (i16)10, (i16)80), (i32)0);
    check("triangle bottom-right outside", inside(tri, (i16)90, (i16)80), (i32)0);
    UXRect tb = tri.boundingBox();
    check("triangle bbox w", (i32)tb.w, (i32)100);
    check("triangle bbox h", (i32)tb.h, (i32)100);

    // even-odd: an outer square with an inner square makes a hole
    UXShapePath* donut = new UXShapePath();
    donut.moveTo((i16)0, (i16)0);
    donut.lineTo((i16)100, (i16)0);
    donut.lineTo((i16)100, (i16)100);
    donut.lineTo((i16)0, (i16)100);
    donut.close();
    donut.moveTo((i16)25, (i16)25);
    donut.lineTo((i16)75, (i16)25);
    donut.lineTo((i16)75, (i16)75);
    donut.lineTo((i16)25, (i16)75);
    donut.close();
    check("in the ring is inside", inside(donut, (i16)10, (i16)50), (i32)1);
    check("in the hole is outside", inside(donut, (i16)50, (i16)50), (i32)0);
    check("far outside", inside(donut, (i16)200, (i16)50), (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXShapePath — bounding box, containment, triangle, even-odd hole.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
