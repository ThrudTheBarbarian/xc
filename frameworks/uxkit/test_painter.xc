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
    i32 firstA;
    i32 lastR;
    i32 lastG;
    i32 lastB;
    i32 lastA;
    void init(void)
        {
        self.reset();
        }
    bool hasThemeArt(void)
        {
        return false;
        }
    // The recorder answers blendsAlpha true: it is not measured on pixels here, only on the colour
    // words it is handed, and alpha has to reach it to be asserted at all.
    bool blendsAlpha(void)
        {
        return true;
        }
    void reset(void)
        {
        polys = (i32)0;
        points = (i32)0;
        any = false;
        strokeCount = (i32)0;
        strokeA = (i32)-1;
        strokeJoin = (i32)-1;
        strokeDashN = (i32)-1;
        strokeDashA = (i32)-1;
        strokePhase = (i32)-999;
        clears = (i32)0;
        textWeight = (i32)-1;
        textItalic = (i32)-1;
        textR = (i32)-1;
        textA = (i32)-1;
        minx = (i32)0;
        miny = (i32)0;
        maxx = (i32)0;
        maxy = (i32)0;
        firstR = (i32)-1;
        firstG = (i32)-1;
        firstB = (i32)-1;
        firstA = (i32)-1;
        lastR = (i32)-1;
        lastG = (i32)-1;
        lastB = (i32)-1;
        lastA = (i32)-1;
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
    void fillPolygonRGBA(i16* xy, i32 n, i32 red, i32 green, i32 blue, i32 alpha)
        {
        if (firstR < (i32)0)
            {
            firstR = red;
            firstG = green;
            firstB = blue;
            firstA = alpha;
            }
        lastR = red;
        lastG = green;
        lastB = blue;
        lastA = alpha;
        self.note(xy, n);
        }
    // The recorder reports NO native stroking, so the tests below exercise the neutral stroker — the
    // one GEM uses, and the only one whose geometry is ours to assert.  A native stroke is the
    // backend's own arithmetic; what matters there is that it is asked for at all, which strokeCount
    // records.  `native` flips it to exercise the path the AppKit ink actually takes.
    i32 strokeCount;
    i32 strokeA;
    i32 strokeJoin;
    i32 strokeDashN;
    i32 strokeDashA;
    i32 strokePhase;
    bool native;
    bool dashes;
    bool strokesNatively(void)
        {
        return native;
        }
    bool dashesNatively(void)
        {
        return dashes;
        }
    // The width is a double (device pixels, fraction and all), so the recorder keeps it as one and a
    // test can ask what fraction a caller passed rather than what an int made of it.
    double strokeWidth;
    void strokeNative(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                      i32* dash, i32 ndash, i32 phase, i32 pen)
        {
        strokeCount = strokeCount + (i32)1;
        strokeWidth = width;
        strokeJoin = join;
        strokeDashN = ndash;
        strokePhase = phase;
        strokeDashA = ndash > (i32)0 ? dash[0] : (i32)0;
        }
    void strokeNativeRGB(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                         i32* dash, i32 ndash, i32 phase, i32 red, i32 green, i32 blue)
        {
        strokeCount = strokeCount + (i32)1;
        strokeWidth = width;
        strokeJoin = join;
        strokeDashN = ndash;
        strokePhase = phase;
        strokeDashA = ndash > (i32)0 ? dash[0] : (i32)0;
        }
    void strokeNativeRGBA(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                          i32* dash, i32 ndash, i32 phase, i32 red, i32 green, i32 blue, i32 alpha)
        {
        strokeCount = strokeCount + (i32)1;
        strokeA = alpha;
        strokeWidth = width;
        strokeJoin = join;
        strokeDashN = ndash;
        strokePhase = phase;
        strokeDashA = ndash > (i32)0 ? dash[0] : (i32)0;
        }

    // The rest of the protocol: a recorder draws none of it.
    i32 clears;
    i32 pixelCalls;
    void drawPixels(u8* data, i32 w, i32 h, i32 format, UXRect src, UXRect dst, i32 alpha)
        {
        pixelCalls = pixelCalls + (i32)1;
        }
    void clearRect(UXRect r)
        {
        clears = clears + (i32)1;
        }
    void fillRect(UXRect r, i32 pen)
        {
        }
    void fillRectRGB(UXRect r, i32 red, i32 green, i32 blue)
        {
        }
    void fillRectRGBA(UXRect r, i32 red, i32 green, i32 blue, i32 alpha)
        {
        }
    void drawTheme(u8* slice, UXRect r)
        {
        }
    void drawText(u8* s, i16 x, i16 y, i32 pen, i32 size)
        {
        }
    void drawTextRGBA(u8* s, i16 x, i16 y, i32 red, i32 green, i32 blue, i32 alpha, i32 size)
        {
        }
    void drawTextFont(u8* s, i16 x, i16 y, i32 pen, u8* family, i32 size, bool bold, bool italic)
        {
        }
    // The face-and-colour-at-once call: recorded so the test can assert the weight and the alpha reach
    // the seam, which is all a recorder can see (the *face* that resolves is the backend's to show).
    i32 textWeight;
    i32 textItalic;
    i32 textR;
    i32 textA;
    void drawTextFontRGBA(u8* s, i16 x, i16 y, u8* family, i32 size, i32 weight, bool italic,
                          i32 red, i32 green, i32 blue, i32 alpha)
        {
        textWeight = weight;
        textItalic = italic ? (i32)1 : (i32)0;
        textR = red;
        textA = alpha;
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

    // ---- alpha reaches the seam ------------------------------------------------------------------
    // The neutral stroker hands every quad and join to the seam as a fill, so a translucent stroke
    // has to carry its alpha there as alpha, not arrive opaque.
    g.reset();
    UXShapePath* ink = new UXShapePath();
    ink.moveTo((i16)20, (i16)20);
    ink.lineTo((i16)120, (i16)40);
    UXPainter.strokePath(g, ink, (i16)8, UXPainter.rgba((i32)248, (i32)244, (i32)230, (i32)235));
    check("a translucent stroke carries its red", g.firstR, (i32)248);
    check("...its green", g.firstG, (i32)244);
    check("...its blue", g.firstB, (i32)230);
    check("...and its alpha", g.firstA, (i32)235);
    // A colour word is either a pen or a packed true colour, and the two must not be confused: a pen
    // is 0..255, a true colour has bits above 7 set.
    checkTrue("a pen is not a true colour", !UXPainter.isRGB((i32)250));
    checkTrue("a packed colour is", UXPainter.isRGB(UXPainter.rgb((i32)1, (i32)2, (i32)3)));
    check("rgb() packs opaque", UXPainter.alphaOf(UXPainter.rgb((i32)1, (i32)2, (i32)3)), (i32)255);
    check("rgba() packs the alpha", UXPainter.alphaOf(UXPainter.rgba((i32)1, (i32)2, (i32)3, (i32)31)), (i32)31);
    // The native stroker takes the same colour word, so it must receive the alpha too: on AppKit the
    // map's ink is strokes, and that is the path they take.
    g.reset();
    g.native = true;
    ink.setJoin((i32)UXJOIN_MITER);
    UXPainter.strokePath(g, ink, (i16)8, UXPainter.rgba((i32)10, (i32)20, (i32)30, (i32)31));
    g.native = false;
    check("a native stroke is asked for once", g.strokeCount, (i32)1);
    check("...with the alpha the colour carried", g.strokeA, (i32)31);
    // The path's join reaches the native stroke; a path that never sets one strokes round, which is
    // what the neutral stroker always drew.
    check("...with the join the path asked for", g.strokeJoin, (i32)UXJOIN_MITER);
    UXShapePath* unjoined = UXShapePath.rect((i16)0, (i16)0, (i16)10, (i16)10);
    check("an unset join is round", unjoined.joinKind(), (i32)UXJOIN_ROUND);

    // ---- a FRACTIONAL width -------------------------------------------------------------------------
    // A pen of 1.536 is a pen of 1.536.  The map's border crawl strokes at 1.536 px and its route
    // dashes at 1.28, so an integer width loses the difference: the recorded double is the value that
    // REACHED the backend, and the seam is the only place it could have been rounded away.
    g.reset();
    g.native = true;
    UXShapePath* hair = new UXShapePath();
    hair.moveTo((i16)10, (i16)10);
    hair.lineTo((i16)90, (i16)10);
    UXPainter.strokePath(g, hair, 1.536, UXPainter.rgb((i32)0, (i32)0, (i32)0));
    check("a fractional width reaches the backend unchanged",
          (i32)(g.strokeWidth * 1000.0 + 0.5), (i32)1536);
    // And where there is no backend stroker at all, the neutral one quantises it to the 1/16 px it
    // works in (1.536 * 16 = 24.576 -> 25, which is 1.5625 px): one pixel FATTER than a 1px stroke,
    // where a seam that truncated the fraction would leave it exactly 1px.
    g.reset();
    g.native = false;
    UXPainter.strokePath(g, hair, 1.536, UXPainter.rgb((i32)0, (i32)0, (i32)0));
    i32 hairTall = g.maxy - g.miny;
    g.reset();
    UXPainter.strokePath(g, hair, 1.0, UXPainter.rgb((i32)0, (i32)0, (i32)0));
    i32 thinTall = g.maxy - g.miny;
    check("the neutral stroker keeps the fraction (1.536 px is fatter than 1 px)", hairTall - thinTall, (i32)1);
    g.reset();
    g.native = true;

    // ---- a ZERO width is floored, never a silent absence --------------------------------------------
    // No backend strokes at width 0, so a zero is a fault: it draws nothing at all, and nothing is
    // never the wanted picture.  The seam floors it to a hairline, so the fault is a thin line (which
    // can be seen and judged) rather than an empty run (which cannot).  A bare float literal passed in
    // the wrong register is one way to reach it, and this is the check that the floor holds.
    g.reset();
    g.native = true;
    UXPainter.strokePath(g, hair, 0.0, UXPainter.rgb((i32)0, (i32)0, (i32)0));
    check("a zero width still reaches the backend as a stroke", g.strokeCount, (i32)1);
    check("...floored to a hairline", (i32)(g.strokeWidth * 1000.0 + 0.5), (i32)1000);
    g.reset();
    g.native = false;
    UXPainter.strokePath(g, hair, 0.0, UXPainter.rgb((i32)0, (i32)0, (i32)0));
    i32 zeroTall = g.maxy - g.miny;
    g.reset();
    UXPainter.strokePath(g, hair, 1.0, UXPainter.rgb((i32)0, (i32)0, (i32)0));
    check("the neutral stroker draws the floored hairline, not nothing", zeroTall, g.maxy - g.miny);
    checkTrue("...and it is a line, not an absence", zeroTall > (i32)0);
    g.reset();
    g.native = true;

    // ---- the dash -----------------------------------------------------------------------------------
    // A dash is a run in device pixels plus a phase into it, and both travel WITH the call: the map's
    // border crawl is a different phase every frame, so a dash held as state would leak into the next
    // stroke that did not set one.  A backend that can dash is handed the run; one that strokes but
    // cannot dash is handed nothing and gets the neutral dasher's pieces, rather than a silently solid
    // border — which is why the capability is asked instead of assumed.
    UXShapePath* dashed = UXShapePath.rect((i16)0, (i16)0, (i16)60, (i16)0);
    i32 pat[2];
    pat[0] = (i32)19;
    pat[1] = (i32)11;
    dashed.setDash(&pat[0], (i32)2, (i32)-5);
    check("a dash run is held on the path", dashed.dashCount(), (i32)2);
    check("...with its first length", dashed.dashAt((i32)0), (i32)19);
    check("...and its phase, which may be negative", dashed.dashPhase(), (i32)-5);
    g.reset();
    g.native = true;
    g.dashes = true;
    UXPainter.strokePath(g, dashed, (i16)2, UXPainter.rgb((i32)0, (i32)0, (i32)0));
    check("a backend that can dash is asked once", g.strokeCount, (i32)1);
    check("...and is handed the run", g.strokeDashN, (i32)2);
    check("...its lengths", g.strokeDashA, (i32)19);
    check("...and the phase", g.strokePhase, (i32)-5);
    // The same path on a backend that strokes but has no dasher of its own (GDI): not asked, and the
    // pieces are drawn here instead.
    g.reset();
    g.native = true;
    g.dashes = false;
    UXPainter.strokePath(g, dashed, (i16)2, UXPainter.rgb((i32)0, (i32)0, (i32)0));
    check("a backend that cannot dash is not asked to", g.strokeCount, (i32)0);
    checkTrue("...it is drawn the neutral dasher's pieces", g.polys > (i32)1);
    // An undashed stroke on the same backend is untouched: no run, one call.
    g.reset();
    g.native = true;
    g.dashes = true;
    UXShapePath* solid = UXShapePath.rect((i16)0, (i16)0, (i16)60, (i16)0);
    UXPainter.strokePath(g, solid, (i16)2, UXPainter.rgb((i32)0, (i32)0, (i32)0));
    check("an undashed stroke passes no run", g.strokeDashN, (i32)0);
    check("...and is still one native call", g.strokeCount, (i32)1);
    g.native = false;
    g.dashes = false;

    // ---- the face with the colour ------------------------------------------------------------------
    // A map label needs a family AND a weight AND a colour AND an alpha in one call; the seam must be
    // handed all four, none folded into a neighbouring argument.  The weight is a number, not a bool:
    // 600 is semibold, which `bold` cannot say.
    g.reset();
    g.drawTextFontRGBA((u8*)"N", (i16)4, (i16)5, (u8*)"ui-monospace", (i32)10,
                       (i32)UXWEIGHT_SEMIBOLD, false, (i32)70, (i32)80, (i32)90, (i32)200);
    check("the semibold weight reaches the seam", g.textWeight, (i32)UXWEIGHT_SEMIBOLD);
    check("...as a number, not a bool", g.textWeight, (i32)600);
    check("...with the label's red", g.textR, (i32)70);
    check("...and its alpha", g.textA, (i32)200);
    check("an upright face stays upright", g.textItalic, (i32)0);

    // ---- the empty layer ---------------------------------------------------------------------------
    // A layer over a map starts each frame cleared, and a source-over fill at alpha 0 is NOT a clear
    // (it paints nothing and leaves last frame's ink).  So the seam has clearRect of its own, and it
    // must reach the backend as a clear and not as a fill.
    g.reset();
    g.clearRect(UXGeom.make((i16)0, (i16)0, (i16)100, (i16)50));
    check("a clear reaches the backend as a clear", g.clears, (i32)1);

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

    // A rounded rectangle is ONE polygon -- four corners of 8 segments, 9 points each, 36 in all --
    // that lies inside its rect, and a radius of 0 is a plain rectangle (the seam's fillRect).
    RecG* rr = new RecG();
    UXPainter.fillRoundRectRGBA((UXGraphics*)rr, UXGeom.make((i16)10, (i16)20, (i16)100, (i16)40),
                                (i32)10, (i32)200, (i32)100, (i32)50, (i32)255);
    check("a rounded rect is one polygon", rr.polys, (i32)1);
    check("...of 36 points (four 8-segment corners)", rr.points, (i32)36);
    checkTrue("...inside its rect", rr.minx >= (i32)10 && rr.maxx <= (i32)110 && rr.miny >= (i32)20 && rr.maxy <= (i32)60);
    RecG* rr0 = new RecG();
    UXPainter.fillRoundRectRGBA((UXGraphics*)rr0, UXGeom.make((i16)0, (i16)0, (i16)20, (i16)20),
                                (i32)0, (i32)0, (i32)0, (i32)0, (i32)255);
    check("radius 0 draws no polygon (it is a plain rectangle)", rr0.polys, (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXPainter — stroking, joins, caps, radial bands.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
