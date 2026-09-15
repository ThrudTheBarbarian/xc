//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx8_point.xc — Point struct + Gfx.at current-position ivar
// + Point-taking moveTo / lineTo / bezierTo overloads. Verifies
// the new and the legacy (i16, i16) signatures stay in lock-step
// and `currentPoint()` round-trips through `moveTo(Point)`.

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx8.xc"

void main(void)
{
    Assert.reset();
    u8* buf = new u8[7680];
    Gfx8* g = new Gfx8(buf);
    g.setPen(1);

    // ── Initial at = (0, 0) -------------------------------
    Assert.isEqual((u16)g.currentX(), 0);             // T1
    Assert.isEqual((u16)g.currentY(), 0);             // T2

    // ── moveTo(i16, i16) updates the at-position ---------
    g.moveTo(50, 30);
    Assert.isEqual((u16)g.currentX(), 50);            // T3
    Assert.isEqual((u16)g.currentY(), 30);            // T4

    // ── moveTo(Point) takes a struct value ---------------
    Point dest;
    dest.x = 100;
    dest.y = 60;
    g.moveTo(dest);
    Assert.isEqual((u16)g.currentX(), 100);           // T5
    Assert.isEqual((u16)g.currentY(), 60);            // T6

    // ── lineTo(i16, i16) updates at to the new endpoint --
    g.setFillColor(0); g.clear();
    g.moveTo(0, 0);
    g.lineTo(8, 0);
    Assert.isEqual((u16)g.currentX(), 8);             // T7
    Assert.isEqual((u16)g.currentY(), 0);             // T8

    // ── lineTo(Point) does the same ----------------------
    Point next;
    next.x = 16;
    next.y = 0;
    g.lineTo(next);
    Assert.isEqual((u16)g.currentX(), 16);            // T9
    Assert.isEqual((u16)g.currentY(), 0);             // T10

    // ── bezierTo(i16, i16, i16, i16) advances at to p2 ---
    g.moveTo(0, 0);
    g.bezierTo(32, 0, 64, 16);
    Assert.isEqual((u16)g.currentX(), 64);            // T11
    Assert.isEqual((u16)g.currentY(), 16);            // T12

    // ── bezierTo(Point, Point) overload --------------------
    Point p1; p1.x = 32; p1.y = 0;
    Point p2; p2.x = 96; p2.y = 8;
    g.moveTo(0, 0);
    g.bezierTo(p1, p2);
    Assert.isEqual((u16)g.currentX(), 96);            // T13
    Assert.isEqual((u16)g.currentY(), 8);             // T14

    // ── currentPoint() returns at by value -----------------
    g.moveTo(40, 24);
    Point cp = g.currentPoint();
    Assert.isEqual((u16)cp.x, 40);                    // T15
    Assert.isEqual((u16)cp.y, 24);                    // T16

    Stdio.printf("DONE 16\n");
    return;
}
