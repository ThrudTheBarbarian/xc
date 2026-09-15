// test_painter.xc — stroking and filling vector shapes, with no backend underneath.
//
// UXPainter turns a path into polygons and hands them to UXGraphics.  That means it can be tested
// against a RECORDING UXGraphics that keeps what it was asked to draw — no window, no driver, no
// pixels — and the assertions are about the geometry the backends will receive.  Which is the whole
// argument for doing stroking neutrally: if this is right, all three backends are right.
#import <Stdio.xc>
#import "UXPainter.xc"
#import "UXShapePath.xc"
#import "UXGradient.xc"

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
void checkTrue(u8* what, bool cond)
    {
    if (cond)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

// A graphics that draws nothing and remembers everything.
class RecG : Object<UXGraphics>
    {
    i32 polys;
    i32 points;
    i32 minx;
    i32 miny;
    i32 maxx;
    i32 maxy;
    bool any;
    i32 firstR;
    i32 firstG;
    i32 firstB;
    i32 lastR;
    i32 lastG;
    i32 lastB;
    void init(void)
        {
        self.reset();
        }
    bool hasThemeArt(void)
        {
        return false;
        }
    void reset(void)
        {
        polys = (i32)0;
        points = (i32)0;
        any = false;
        strokeCount = (i32)0;
        minx = (i32)0;
        miny = (i32)0;
        maxx = (i32)0;
        maxy = (i32)0;
        firstR = (i32)-1;
        firstG = (i32)-1;
        firstB = (i32)-1;
        lastR = (i32)-1;
        lastG = (i32)-1;
        lastB = (i32)-1;
        }
    void note(i16* xy, i32 n)
        {
        polys = polys + (i32)1;
        points = points + n;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            i32 x = (i32)xy[i * (i32)2];
            i32 y = (i32)xy[i * (i32)2 + (i32)1];
            if (!any)
                {
                minx = x;
                maxx = x;
                miny = y;
                maxy = y;
                any = true;
                }
            else
                {
                if (x < minx)
                    {
                    minx = x;
                    }
                if (x > maxx)
                    {
                    maxx = x;
                    }
                if (y < miny)
                    {
                    miny = y;
                    }
                if (y > maxy)
                    {
                    maxy = y;
                    }
                }
            }
        }
    void fillPolygon(i16* xy, i32 n, i32 pen)
        {
        self.note(xy, n);
        }
    void fillPolygonRGB(i16* xy, i32 n, i32 red, i32 green, i32 blue)
        {
        if (firstR < (i32)0)
            {
            firstR = red;
            firstG = green;
            firstB = blue;
            }
        lastR = red;
        lastG = green;
        lastB = blue;
        self.note(xy, n);
        }
    // The recorder reports NO native stroking, so the tests below exercise the neutral stroker — the
    // one GEM uses, and the only one whose geometry is ours to assert.  A native stroke is the
    // backend's own arithmetic; what matters there is that it is asked for at all, which strokeCount
    // records.
    i32 strokeCount;
    bool strokesNatively(void)
        {
        return false;
        }
    void strokeNative(i32* ops, i32 n, i32 width, i32 startCap, i32 endCap, i32 pen)
        {
        strokeCount = strokeCount + (i32)1;
        }
    void strokeNativeRGB(i32* ops, i32 n, i32 width, i32 startCap, i32 endCap,
                         i32 red, i32 green, i32 blue)
        {
        strokeCount = strokeCount + (i32)1;
        }

    // The rest of the protocol: a recorder draws none of it.
    void fillRect(UXRect r, i32 pen)
        {
        }
    void fillRectRGB(UXRect r, i32 red, i32 green, i32 blue)
        {
        }
    void drawTheme(u8* slice, UXRect r)
        {
        }
    void drawText(u8* s, i16 x, i16 y, i32 pen, i32 size)
        {
        }
    void drawTextFont(u8* s, i16 x, i16 y, i32 pen, u8* family, i32 size, bool bold, bool italic)
        {
        }
    void fillTriangle(i16 x0, i16 y0, i16 x1, i16 y1, i16 x2, i16 y2, i32 pen)
        {
        }
    void fillCircle(i16 cx, i16 cy, i16 r, i32 pen)
        {
        }
    void drawLine(i16 x0, i16 y0, i16 x1, i16 y1, i32 pen)
        {
        }
    }

    // The 1..5px range, in its own function: main was over xtc's 16KB arm64 frame budget with this
    // inline, which is a build error rather than a warning.
    void thinStrokes(RecG* g)
    {
    // ---- THIN strokes: 1..5px, which is what most curves actually are ---------------------------
    // The awkward end of the range.  At 1px the half-width is half a pixel, so both edges of a quad
    // can round to the same coordinate and the stroke can vanish; at 1px there is also no room for a
    // join disc, so consecutive quads on a curve meet edge to edge with nothing covering the seam.
    for (i32 w = (i32)1; w <= (i32)5; w = w + (i32)1)
        {
        g.reset();
        UXShapePath* horiz = new UXShapePath();
        horiz.moveTo((i16)10, (i16)100);
        horiz.lineTo((i16)110, (i16)100);
        UXPainter.strokePath(g, horiz, (i16)w, (i32)1);
        // A horizontal segment's quad is exactly as tall as the stroke is wide — no thinner (which
        // would drop out at 1px) and no fatter (which would make a 1px rule look like 2).
        check("a horizontal stroke is exactly its width tall", g.maxy - g.miny, w);
        check("...and still one quad", g.polys, (i32)1);

        g.reset();
        UXShapePath* vert = new UXShapePath();
        vert.moveTo((i16)50, (i16)10);
        vert.lineTo((i16)50, (i16)110);
        UXPainter.strokePath(g, vert, (i16)w, (i32)1);
        check("a vertical stroke is exactly its width across", g.maxx - g.minx, w);
        }
    // A curve at 1px: joins have no room, so the quads must abut with no gap — which they do only
    // because strokeSegment stopped overhanging its ends (an overhang would spur at every vertex).
    g.reset();
    UXShapePath* arc = new UXShapePath();
    arc.moveTo((i16)10, (i16)60);
    arc.curveTo((i16)24, (i16)26, (i16)58, (i16)26, (i16)72, (i16)60);
    UXPainter.strokePath(g, arc, (i16)1, (i32)1);
    i32 thinPolys = g.polys;
    checkTrue("a 1px curve is many quads", thinPolys > (i32)10);
    g.reset();
    UXPainter.strokePath(g, arc, (i16)5, (i32)1);
    checkTrue("a 5px curve adds join discs on top of the same quads", g.polys > thinPolys);
    }

void main(void)
    {
    gFails = (i32)0;
    RecG* g = new RecG();

    // ---- a straight stroke ----------------------------------------------------------------------
    UXShapePath* line = new UXShapePath();
    line.moveTo((i16)100, (i16)100);
    line.lineTo((i16)200, (i16)100);
    UXPainter.strokePath(g, line, (i16)16, (i32)1);
    check("one segment strokes as one quad", g.polys, (i32)1);
    check("...of four points", g.points, (i32)4);
    // Exactly the segment swept by the width — no overhang.  An earlier version stretched each quad
    // a pixel past its ends so neighbours would overlap rather than abut, which does avoid the
    // antialiasing seam but pokes a spur past EVERY vertex of a flattened curve; hundreds of them
    // read as a bumpy silhouette.  The join disc covers the seam instead, and costs no smoothness.
    check("the stroke spans exactly the segment", g.maxx - g.minx, (i32)100);
    check("...and is the full width across it", g.maxy - g.miny, (i32)16);
    checkTrue("...centred on the path, not offset to one side",
              g.miny == (i32)92 && g.maxy == (i32)108);

    // ---- a corner gets a join -------------------------------------------------------------------
    g.reset();
    UXShapePath* bent = new UXShapePath();
    bent.moveTo((i16)100, (i16)100);
    bent.lineTo((i16)200, (i16)100);
    bent.lineTo((i16)200, (i16)200);
    UXPainter.strokePath(g, bent, (i16)16, (i32)1);
    check("two segments and the join between them", g.polys, (i32)3);
    // Without the join, a right-angle corner leaves a visible notch on the outside of the turn.
    checkTrue("the join is a disc, not another quad", g.points > (i32)8 + (i32)4);

    // Even a 2px stroke gets its join.  This used to skip any width under 4 on the theory that the
    // quads already meet at that size — they do not: they meet at an ANGLE and leave a notch on the
    // outside of every turn, so a thin outline round a curve came out visibly polygonal, and it read
    // as the curve being faceted rather than its outline.  Only a zero-radius join can be skipped.
    g.reset();
    UXPainter.strokePath(g, bent, (i16)2, (i32)1);
    check("even a 2px corner gets a join", g.polys, (i32)3);
    g.reset();
    UXPainter.strokePath(g, bent, (i16)1, (i32)1);
    check("a 1px stroke has no room for one", g.polys, (i32)2);

    // ---- caps are extra pieces -------------------------------------------------------------------
    g.reset();
    UXShapePath* capped = new UXShapePath();
    capped.moveTo((i16)100, (i16)100);
    capped.lineTo((i16)200, (i16)100);
    capped.setStartCap((i32)UXCAP_ROUND);
    capped.setEndCap((i32)UXCAP_ARROW);
    UXPainter.strokePath(g, capped, (i16)16, (i32)1);
    check("quad plus two caps", g.polys, (i32)3);
    // The outlined form: a wide body pass, the ARROWHEAD OUTLINED SEPARATELY (its own triangle
    // stroked, because a bigger similar triangle is not an offset one — the rim would pinch to
    // nothing at the tip and vanish across the rear edge), then the fill pass on top.
    g.reset();
    UXPainter.strokeOutlined(g, capped, (i16)16, (i32)1, (i32)1, (i16)3);
    i32 outlined = g.polys;
    g.reset();
    UXPainter.strokePath(g, capped, (i16)16, (i32)1);
    checkTrue("an outlined stroke costs more than a plain one — the arrow is outlined too",
              outlined > g.polys);
    // The arrowhead sticks out past the end of the line — that is what an arrowhead is.
    checkTrue("the arrow reaches beyond the path's end", g.maxx > (i32)200);
    // ...and the round cap past the start.
    checkTrue("the round cap reaches before the path's start", g.minx < (i32)100);

    // ---- a curve strokes as its flattening -------------------------------------------------------
    g.reset();
    UXShapePath* curve = new UXShapePath();
    curve.moveTo((i16)100, (i16)200);
    curve.curveTo((i16)100, (i16)100, (i16)300, (i16)100, (i16)300, (i16)200);
    UXPainter.strokePath(g, curve, (i16)16, (i32)1);
    checkTrue("a curve strokes as many quads and joins", g.polys > (i32)10);
    checkTrue("the stroke stays within the curve plus its half-width",
              g.minx >= (i32)90 && g.maxx <= (i32)310);

    thinStrokes(g);

    // ---- radial fill ------------------------------------------------------------------------------
    g.reset();
    UXGradient* grad = new UXGradient();
    UXColor* mid = new UXColor();
    mid.r = (u8)255;
    mid.g = (u8)255;
    mid.b = (u8)0; // yellow centre
    UXColor* edge = new UXColor();
    edge.r = (u8)0;
    edge.g = (u8)0;
    edge.b = (u8)255; // blue edge
    grad.addStop((i32)0, mid);
    grad.addStop((i32)255, edge);
    UXShapePath* box = UXShapePath.rect((i16)0, (i16)0, (i16)100, (i16)100);
    UXPainter.fillShapeRadial(g, box, grad, (i32)16);
    check("one polygon per band", g.polys, (i32)16);
    // The FIRST band drawn is the outermost, so it must carry the edge colour, and the last the
    // centre colour.  Drawing them the other way round paints the centre first and buries it.
    checkTrue("the first band is the edge colour", g.firstB > (i32)200 && g.firstR < (i32)60);
    checkTrue("the last band is the centre colour", g.lastR > (i32)200 && g.lastG > (i32)200);
    // Bands shrink toward the middle: nothing may escape the shape.
    checkTrue("no band escapes the shape", g.minx >= (i32)0 && g.maxx <= (i32)100);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXPainter — stroking, joins, caps, radial bands.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
