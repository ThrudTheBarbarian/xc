// UXShapePath.xc — a vector path with CURVES (NSBezierPath in shape).
//
// Build shapes with moveTo / lineTo / curveTo / quadTo / close; ask for the bounding box and whether
// a point is inside (even-odd fill via ray casting).  Multiple subpaths are supported and each is
// implicitly closed for containment.  This is what a custom-shaped control hit-tests against and
// what a drawing tool strokes.  Pure geometry — no driver, no backend, fully testable headless.
//
// CURVES ARE STORED, NOT FLATTENED ON THE WAY IN.  A path keeps the cubic the caller drew, and
// flattened() produces the polyline on demand.  That matters because flattening is lossy and
// resolution-dependent: the same path may want 8 segments in a 40px thumbnail and 200 in a printout,
// and a path that threw its curves away at build time can only ever answer at one of them.  Every
// consumer here (bounds, edges, containment) routes through flattened(), so a curved path behaves
// exactly like the straight-line path it approximates.
//
// The flattener is DE CASTELJAU SUBDIVISION in integer arithmetic: halve the curve, test whether the
// halves are flat enough to be lines, recurse if not.  Halving is add-and-shift, so it cannot
// overflow the way evaluating B(t) at t=i/n can — that route needs n^3 * coordinate, which leaves
// i32 at around n=16 and xt has no 64-bit integer.  Integer throughout also means every backend
// flattens a given path to the SAME pixels, rather than each rounding a float differently.
#import "Array.xc"
#import "UXGeometry.xc"

#define UXPE_MOVE 0
#define UXPE_LINE 1
#define UXPE_CLOSE 2
#define UXPE_CURVE 3 // cubic: c1/c2 are the control points, x/y the on-curve end

// How far a flattened chord may sit from the true curve before it is subdivided again, as 1/N of a
// pixel.  4 = a quarter pixel.  This was 1 WHOLE pixel measured against a Manhattan chord length,
// which over-estimates the true length by up to 41% and so loosened the real tolerance to ~1.4px:
// a 60px blob came out as a visible octagon and the long curve had flats in it.  The cap on depth is
// what stops a pathological curve subdividing for ever (9 levels = at most 512 segments per curve).
#define UX_FLATTEN_DEN 4
#define UX_FLATTEN_DEPTH 9

// SUB-PIXEL units for the flattener's output.  A path stores whole-pixel coordinates, which is right
// for authoring, but a stroke built from whole-pixel vertices has a silhouette that wobbles by up to
// half a pixel — and a 1px wobble is visible on EVERY backend, antialiased or not.  (It was assumed
// hard pixels would hide it on GEM.  They do not: a pixel is a pixel.)  So the flattener can also
// emit 1/16 px, which the neutral stroker works in and rounds ONCE, at the end.
#define UX_FX 16
#define UX_FX_MOVE (-2000000) // markers no real coordinate can hold
#define UX_FX_CLOSE (-2000001)

// Stroke CAPS — what to draw at the two loose ends of an open path.  They live on the path because
// they are a property of the shape the author drew, not of the backend that happens to render it,
// and because the cap geometry is the same integer arithmetic as everything else here.  A closed
// subpath has no ends and no caps.
#define UXCAP_NONE 0   // stop dead at the endpoint (butt)
#define UXCAP_ROUND 1  // a half-disc of the stroke width
#define UXCAP_SQUARE 2 // a half-width square extension
#define UXCAP_ARROW 3  // an arrowhead pointing the way the path was going

// cos/sin of k*22.5 degrees scaled by 256, k = 0..8 — a half turn, which is all a round cap needs.
// A table rather than repeated rotation of a vector: rotating accumulates error, and at 1/256 the
// drift is visible by the eighth step.
i32 gUXArcC[9];
i32 gUXArcS[9];
bool gUXArcReady;
void xgArcInit(void)
    {
    if (gUXArcReady)
        {
        return;
        }
    gUXArcC[0] = (i32)256;
    gUXArcS[0] = (i32)0;
    gUXArcC[1] = (i32)237;
    gUXArcS[1] = (i32)98;
    gUXArcC[2] = (i32)181;
    gUXArcS[2] = (i32)181;
    gUXArcC[3] = (i32)98;
    gUXArcS[3] = (i32)237;
    gUXArcC[4] = (i32)0;
    gUXArcS[4] = (i32)256;
    gUXArcC[5] = (i32)-98;
    gUXArcS[5] = (i32)237;
    gUXArcC[6] = (i32)-181;
    gUXArcS[6] = (i32)181;
    gUXArcC[7] = (i32)-237;
    gUXArcS[7] = (i32)98;
    gUXArcC[8] = (i32)-256;
    gUXArcS[8] = (i32)0;
    gUXArcReady = true;
    }

class UXPathElement : Object
    {
    i32 type;
    i16 x;
    i16 y;
    i16 c1x;
    i16 c1y;
    i16 c2x;
    i16 c2y; // UXPE_CURVE only: the two off-curve control points
    void init(void)
        {
        type = (i32)UXPE_MOVE;
        x = (i16)0;
        y = (i16)0;
        c1x = (i16)0;
        c1y = (i16)0;
        c2x = (i16)0;
        c2y = (i16)0;
        }
    } class UXEdge : Object
    {
    i16 x0;
    i16 y0;
    i16 x1;
    i16 y1;
    void init(void)
        {
        x0 = (i16)0;
        y0 = (i16)0;
        x1 = (i16)0;
        y1 = (i16)0;
        }
    }

    class UXShapePath
    {
    Array<UXPathElement>* elements;
    bool curved; // any UXPE_CURVE present — flattened() is a no-op when false
    i16 lastX;
    i16 lastY; // the current point, for quadTo's control-point elevation
    i32 startCap;
    i32 endCap;
    i16 capWidth; // the stroke width the caps are built for (0 = ask at cap time)
    i16 arrowLen; // arrowhead length along the direction of travel (0 = 3x the width)

    void init(void)
        {
        elements = new Array();
        curved = false;
        lastX = (i16)0;
        lastY = (i16)0;
        startCap = (i32)UXCAP_NONE;
        endCap = (i32)UXCAP_NONE;
        capWidth = (i16)0;
        arrowLen = (i16)0;
        }

    void add(i32 type, i16 x, i16 y)
        {
        UXPathElement* e = new UXPathElement();
        e.type = type;
        e.x = x;
        e.y = y;
        elements.add(e);
        if (type != (i32)UXPE_CLOSE)
            {
            lastX = x;
            lastY = y;
            }
        }
    void moveTo(i16 x, i16 y)
        {
        self.add((i32)UXPE_MOVE, x, y);
        }
    void lineTo(i16 x, i16 y)
        {
        self.add((i32)UXPE_LINE, x, y);
        }
    void close(void)
        {
        self.add((i32)UXPE_CLOSE, (i16)0, (i16)0);
        }
    i32 elementCount(void)
        {
        return (i32)elements.count();
        }
    bool hasCurves(void)
        {
        return curved;
        }

    // A CUBIC bezier from the current point: two off-curve controls, then the on-curve end.  The
    // same shape as NSBezierPath's curveToPoint:controlPoint1:controlPoint2: and GDI's PolyBezier.
    void curveTo(i16 c1x, i16 c1y, i16 c2x, i16 c2y, i16 x, i16 y)
        {
        UXPathElement* e = new UXPathElement();
        e.type = (i32)UXPE_CURVE;
        e.x = x;
        e.y = y;
        e.c1x = c1x;
        e.c1y = c1y;
        e.c2x = c2x;
        e.c2y = c2y;
        elements.add(e);
        lastX = x;
        lastY = y;
        curved = true;
        }
    // A QUADRATIC, elevated to the cubic the rest of the code speaks: a quadratic with control C is
    // exactly the cubic with c1 = p0 + 2/3(C-p0) and c2 = p3 + 2/3(C-p3).  Storing one curve kind
    // keeps the flattener, the backends and the tests from each having two cases.
    void quadTo(i16 cx, i16 cy, i16 x, i16 y)
        {
        i32 p0x = (i32)lastX;
        i32 p0y = (i32)lastY;
        i32 c1x = p0x + (i32)2 * ((i32)cx - p0x) / (i32)3;
        i32 c1y = p0y + (i32)2 * ((i32)cy - p0y) / (i32)3;
        i32 c2x = (i32)x + (i32)2 * ((i32)cx - (i32)x) / (i32)3;
        i32 c2y = (i32)y + (i32)2 * ((i32)cy - (i32)y) / (i32)3;
        self.curveTo((i16)c1x, (i16)c1y, (i16)c2x, (i16)c2y, x, y);
        }

    // ---- caps -----------------------------------------------------------------
    void setStartCap(i32 c)
        {
        startCap = c;
        }
    void setEndCap(i32 c)
        {
        endCap = c;
        }
    void setCapWidth(i16 w)
        {
        capWidth = w;
        }
    void setArrowLength(i16 n)
        {
        arrowLen = n;
        }
    i16 arrowLength(void)
        {
        return arrowLen;
        }
    i32 startCapKind(void)
        {
        return startCap;
        }
    i32 endCapKind(void)
        {
        return endCap;
        }

    static UXShapePath* rect(i16 x, i16 y, i16 w, i16 h)
        {
        UXShapePath* p = new UXShapePath();
        p.moveTo(x, y);
        p.lineTo((i16)(x + w), y);
        p.lineTo((i16)(x + w), (i16)(y + h));
        p.lineTo(x, (i16)(y + h));
        p.close();
        return p;
        }
    UXPathElement* elemAt(i32 i)
        { return (UXPathElement* ?)elements.get((u16)i);
        }

    // ---- flattening -----------------------------------------------------------
    // Is the cubic p0..p3 close enough to its chord to be drawn as one line?  Both control points
    // must lie within the tolerance of the chord.  The distance from a point to the chord is
    // |cross| / |chord|, so |cross| * DEN <= |chord| is "within 1/DEN of a pixel" with no division.
    // The chord is the TRUE length: Manhattan was cheaper but over-estimates by up to 41%, which
    // made the effective tolerance 1.4px instead of 1px — visible faceting on anything small.
    bool curveIsFlat(i32 p0x, i32 p0y, i32 p1x, i32 p1y, i32 p2x, i32 p2y, i32 p3x, i32 p3y)
        {
        i32 dx = p3x - p0x;
        i32 dy = p3y - p0y;
        i32 chord = UXGeom.length(dx, dy);
        // Nothing left to resolve: a chord of a pixel or less cannot be improved by subdividing,
        // because the points this path stores are INTEGERS and both halves would round to the same
        // pixel.  Without this a 30px circle subdivided to 118 elements of which most were
        // duplicates — every one of them costing a stroke quad and a join disc to draw.
        if (chord <= (i32)1)
            {
            return true;
            }
        i32 c1 = dx * (p1y - p0y) - dy * (p1x - p0x);
        i32 c2 = dx * (p2y - p0y) - dy * (p2x - p0x);
        if (c1 < (i32)0)
            {
            c1 = -c1;
            }
        if (c2 < (i32)0)
            {
            c2 = -c2;
            }
        if (chord == (i32)0)
            {
            // Degenerate chord (a loop returning to its start): the cross products are 0 whatever the
            // controls do, so fall back to measuring the controls against the anchor directly.
            i32 a1 = UXGeom.length(p1x - p0x, p1y - p0y);
            i32 a2 = UXGeom.length(p2x - p0x, p2y - p0y);
            return a1 * (i32)UX_FLATTEN_DEN <= (i32)1 && a2 * (i32)UX_FLATTEN_DEN <= (i32)1;
            }
        return c1 * (i32)UX_FLATTEN_DEN <= chord && c2 * (i32)UX_FLATTEN_DEN <= chord;
        }

    // Halve the curve and recurse, emitting lineTo for each piece that is flat enough.  Every
    // midpoint is (a+b)/2 on i32, so no step can overflow however deep it goes — the depth cap is
    // there for curves that are flat by no tolerance (a cusp), not for safety.
    void flattenCurve(UXShapePath* out, i32 p0x, i32 p0y, i32 p1x, i32 p1y,
                      i32 p2x, i32 p2y, i32 p3x, i32 p3y, i32 depth)
        {
        if (depth >= (i32)UX_FLATTEN_DEPTH || self.curveIsFlat(p0x, p0y, p1x, p1y, p2x, p2y, p3x, p3y))
            {
            out.lineTo((i16)p3x, (i16)p3y);
            return;
            }
        i32 ax = (p0x + p1x) / (i32)2;
        i32 ay = (p0y + p1y) / (i32)2; // de Casteljau, one level
        i32 bx = (p1x + p2x) / (i32)2;
        i32 by = (p1y + p2y) / (i32)2;
        i32 cx = (p2x + p3x) / (i32)2;
        i32 cy = (p2y + p3y) / (i32)2;
        i32 dx = (ax + bx) / (i32)2;
        i32 dy = (ay + by) / (i32)2;
        i32 ex = (bx + cx) / (i32)2;
        i32 ey = (by + cy) / (i32)2;
        i32 mx = (dx + ex) / (i32)2;
        i32 my = (dy + ey) / (i32)2; // the point on the curve
        self.flattenCurve(out, p0x, p0y, ax, ay, dx, dy, mx, my, depth + (i32)1);
        self.flattenCurve(out, mx, my, ex, ey, cx, cy, p3x, p3y, depth + (i32)1);
        }

    // The same path with every curve replaced by the lines that approximate it.  A path with no
    // curves is returned AS IS rather than copied — the straight-line case is the common one and it
    // should cost nothing.
    UXShapePath* flattened(void)
        {
        if (!curved)
            {
            return self;
            }
        UXShapePath* out = new UXShapePath();
        out.startCap = startCap;
        out.endCap = endCap;
        out.capWidth = capWidth;
        out.arrowLen = arrowLen;
        i32 n = (i32)elements.count();
        i16 curX = (i16)0;
        i16 curY = (i16)0;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            UXPathElement* e = self.elemAt(i);
            if (e.type == (i32)UXPE_CURVE)
                {
                self.flattenCurve(out, (i32)curX, (i32)curY, (i32)e.c1x, (i32)e.c1y,
                                  (i32)e.c2x, (i32)e.c2y, (i32)e.x, (i32)e.y, (i32)0);
                curX = e.x;
                curY = e.y;
                }
            else
                {
                out.add(e.type, e.x, e.y);
                if (e.type != (i32)UXPE_CLOSE)
                    {
                    curX = e.x;
                    curY = e.y;
                    }
                }
            }
        return out;
        }

    // Bounds of the SHAPE, not of its control polygon: a cubic's control points routinely sit well
    // outside the curve they steer, so measuring the stored elements would over-report the box —
    // and an over-reported box means over-invalidated repaints.  Flatten first.
    // ---- sub-pixel flattening -------------------------------------------------
    // The same de Casteljau as flattened(), but the arithmetic stays in 1/16 px and the result goes
    // into a caller's array as x,y pairs — a path could only hold whole pixels.  Subpath boundaries
    // are marked with UX_FX_MOVE / UX_FX_CLOSE in the x slot.  Returns the point count.
    //
    // The flatness test works on values divided by 4 so a cross product cannot leave i32: at 1/16 px
    // a 4096px span is 65536, and squaring that overflows.
    bool curveIsFlatFx(i32 p0x, i32 p0y, i32 p1x, i32 p1y, i32 p2x, i32 p2y, i32 p3x, i32 p3y)
        {
        i32 dx = p3x - p0x;
        i32 dy = p3y - p0y;
        i32 chord = UXGeom.length(dx / (i32)4, dy / (i32)4); // quarter-pixel units
        // half a pixel: nothing to gain
        if (chord <= (i32)2)
            {
            return true;
            }
        i32 c1 = (dx / (i32)4) * ((p1y - p0y) / (i32)4) - (dy / (i32)4) * ((p1x - p0x) / (i32)4);
        i32 c2 = (dx / (i32)4) * ((p2y - p0y) / (i32)4) - (dy / (i32)4) * ((p2x - p0x) / (i32)4);
        if (c1 < (i32)0)
            {
            c1 = -c1;
            }
        if (c2 < (i32)0)
            {
            c2 = -c2;
            }
        i32 limit = chord * (i32)4 / (i32)UX_FLATTEN_DEN; // "within 1/DEN of a pixel"
        return c1 <= limit && c2 <= limit;
        }
    i32 flattenCurveFx(i32* out, i32 n, i32 cap, i32 p0x, i32 p0y, i32 p1x, i32 p1y,
                       i32 p2x, i32 p2y, i32 p3x, i32 p3y, i32 depth)
        {
        if (n + (i32)1 > cap)
            {
            return n;
            }
        if (depth >= (i32)UX_FLATTEN_DEPTH || self.curveIsFlatFx(p0x, p0y, p1x, p1y, p2x, p2y, p3x, p3y))
            {
            out[n * (i32)2] = p3x;
            out[n * (i32)2 + (i32)1] = p3y;
            return n + (i32)1;
            }
        i32 ax = (p0x + p1x) / (i32)2;
        i32 ay = (p0y + p1y) / (i32)2;
        i32 bx = (p1x + p2x) / (i32)2;
        i32 by = (p1y + p2y) / (i32)2;
        i32 cx = (p2x + p3x) / (i32)2;
        i32 cy = (p2y + p3y) / (i32)2;
        i32 dx = (ax + bx) / (i32)2;
        i32 dy = (ay + by) / (i32)2;
        i32 ex = (bx + cx) / (i32)2;
        i32 ey = (by + cy) / (i32)2;
        i32 mx = (dx + ex) / (i32)2;
        i32 my = (dy + ey) / (i32)2;
        n = self.flattenCurveFx(out, n, cap, p0x, p0y, ax, ay, dx, dy, mx, my, depth + (i32)1);
        return self.flattenCurveFx(out, n, cap, mx, my, ex, ey, cx, cy, p3x, p3y, depth + (i32)1);
        }
    i32 flattenFx(i32* out, i32 cap)
        {
        i32 n = (i32)0;
        i32 curX = (i32)0;
        i32 curY = (i32)0;
        for (i32 i = (i32)0; i < (i32)elements.count(); i = i + (i32)1)
            {
            UXPathElement* e = self.elemAt(i);
            if (e.type == (i32)UXPE_CLOSE)
                {
                if (n + (i32)1 > cap)
                    {
                    return n;
                    }
                out[n * (i32)2] = (i32)UX_FX_CLOSE;
                out[n * (i32)2 + (i32)1] = (i32)0;
                n = n + (i32)1;
                continue;
                }
            i32 ex = (i32)e.x * (i32)UX_FX;
            i32 ey = (i32)e.y * (i32)UX_FX;
            if (e.type == (i32)UXPE_CURVE)
                {
                n = self.flattenCurveFx(out, n, cap, curX, curY,
                                        (i32)e.c1x * (i32)UX_FX, (i32)e.c1y * (i32)UX_FX,
                                        (i32)e.c2x * (i32)UX_FX, (i32)e.c2y * (i32)UX_FX,
                                        ex, ey, (i32)0);
                }
            else
                {
                if (e.type == (i32)UXPE_MOVE)
                    {
                    if (n + (i32)2 > cap)
                        {
                        return n;
                        }
                    out[n * (i32)2] = (i32)UX_FX_MOVE;
                    out[n * (i32)2 + (i32)1] = (i32)0;
                    n = n + (i32)1;
                    }
                else if (n + (i32)1 > cap)
                    {
                    return n;
                    }
                out[n * (i32)2] = ex;
                out[n * (i32)2 + (i32)1] = ey;
                n = n + (i32)1;
                }
            curX = ex;
            curY = ey;
            }
        return n;
        }

    // ---- caps -----------------------------------------------------------------
    // The direction a cap points: OUTWARD, away from the path.  At the end that is the direction of
    // travel as the path arrives; at the start it is the reverse of the direction it sets off in.
    //
    // Taken from the STORED elements, analytically.  A cubic's tangent at its end is p3 - c2 and at
    // its start c1 - p0, exactly; reading it off the flattened polyline instead gives the last CHORD,
    // which is a different direction — for a curve arriving straight down it came out 9 degrees off,
    // enough to hang the arrowhead visibly askew.  Degenerate controls (a control sitting on its
    // anchor) fall through to the next-best vector rather than producing a zero direction.
    bool capDirection(bool atStart, i32* dx, i32* dy)
        {
        i32 n = (i32)elements.count();
        i32 curX = (i32)0;
        i32 curY = (i32)0;
        bool have = false;
        i32 ax = (i32)0;
        i32 ay = (i32)0;
        bool found = false;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            UXPathElement* e = self.elemAt(i);
            if (e.type == (i32)UXPE_CLOSE)
                {
                continue;
                }
            if (e.type == (i32)UXPE_MOVE)
                {
                curX = (i32)e.x;
                curY = (i32)e.y;
                have = true;
                continue;
                }
            if (!have)
                {
                curX = (i32)e.x;
                curY = (i32)e.y;
                have = true;
                continue;
                }
            // the first segment is all we need
            if (atStart && found)
                {
                break;
                }
            if (atStart)
                {
                if (e.type == (i32)UXPE_CURVE)
                    {
                    ax = curX - (i32)e.c1x;
                    ay = curY - (i32)e.c1y;
                    if (ax == (i32)0 && ay == (i32)0)
                        {
                        ax = curX - (i32)e.c2x;
                        ay = curY - (i32)e.c2y;
                        }
                    }
                else
                    {
                    ax = curX - (i32)e.x;
                    ay = curY - (i32)e.y;
                    }
                if (ax == (i32)0 && ay == (i32)0)
                    {
                    ax = curX - (i32)e.x;
                    ay = curY - (i32)e.y;
                    }
                found = true;
                }
            else
                {
                if (e.type == (i32)UXPE_CURVE)
                    {
                    ax = (i32)e.x - (i32)e.c2x;
                    ay = (i32)e.y - (i32)e.c2y;
                    if (ax == (i32)0 && ay == (i32)0)
                        {
                        ax = (i32)e.x - (i32)e.c1x;
                        ay = (i32)e.y - (i32)e.c1y;
                        }
                    }
                else
                    {
                    ax = (i32)e.x - curX;
                    ay = (i32)e.y - curY;
                    }
                if (ax == (i32)0 && ay == (i32)0)
                    {
                    ax = (i32)e.x - curX;
                    ay = (i32)e.y - curY;
                    }
                found = true;
                }
            curX = (i32)e.x;
            curY = (i32)e.y;
            }
        if (!found || (ax == (i32)0 && ay == (i32)0))
            {
            return false;
            }
        dx[(i32)0] = ax;
        dy[(i32)0] = ay;
        return true;
        }

    // The point a cap sits on: the first or last on-curve point of the path.
    bool capAnchor(bool atStart, i32* ox, i32* oy)
        {
        i32 n = (i32)elements.count();
        bool any = false;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            UXPathElement* e = self.elemAt(i);
            if (e.type == (i32)UXPE_CLOSE)
                {
                continue;
                }
            if (atStart)
                {
                ox[(i32)0] = (i32)e.x;
                oy[(i32)0] = (i32)e.y;
                return true;
                }
            ox[(i32)0] = (i32)e.x;
            oy[(i32)0] = (i32)e.y;
            any = true;
            }
        return any;
        }

    // The cap as a FILLABLE SHAPE — a closed subpath the stroker fills in the stroke colour, rather
    // than a special instruction each backend has to understand.  GEM has no round cap and no
    // arrowhead; Win32's geometric pens have caps but not arrows; AppKit has caps but not arrows.
    // Making the cap a polygon means one description, identical pixels, and nothing to emulate.
    // Returns an empty path for UXCAP_NONE, for a closed path, or for a path with no direction.
    // The cap DILATED outward by `rim` — the shape an outline pass must fill so the rim is the same
    // thickness all the way round.  Round and square caps dilate by simply being drawn at a bigger
    // width; an ARROWHEAD does not, and that is the whole reason this exists.  A bigger SIMILAR
    // triangle is not an offset triangle: its rim pinches to nothing at the tip and disappears
    // entirely across the rear edge, because both triangles share that edge.
    //
    // For an isoceles head with half-base H, length L and slant S = hypot(L,H), moving every edge
    // out by rim gives, by similar triangles:
    //     L' = L + rim*S/H              (the tip runs on, further the sharper the point)
    //     H' = H + H*rim*(S+H)/(S*L) + rim*L/S
    // which is exact, and stays in i32 at any width worth drawing.
    UXShapePath* capOutlineRim(bool atStart, i16 width, i16 rim)
        {
        i32 which = atStart ? startCap : endCap;
        if (which != (i32)UXCAP_ARROW)
            {
            return self.capOutline(atStart, (i16)((i32)width + (i32)2 * (i32)rim));
            }
        UXShapePath* out = new UXShapePath();
        i32 w = (i32)(width > (i16)0 ? width : capWidth);
        if (w <= (i32)0)
            {
            return out;
            }
        i32 dx = (i32)0;
        i32 dy = (i32)0;
        i32 cx = (i32)0;
        i32 cy = (i32)0;
        if (!self.capDirection(atStart, &dx, &dy))
            {
            return out;
            }
        if (!self.capAnchor(atStart, &cx, &cy))
            {
            return out;
            }
        i32 len = UXGeom.length(dx, dy);
        if (len <= (i32)0)
            {
            return out;
            }
        i32 ux = dx * (i32)256 / len;
        i32 uy = dy * (i32)256 / len;
        i32 nx = -uy;
        i32 ny = ux;
        i32 L = (i32)arrowLen > (i32)0 ? (i32)arrowLen : w * (i32)5 / (i32)2;
        i32 H = w;
        i32 S = UXGeom.length(L, H);
        i32 r = (i32)rim;
        i32 Lp = L + (r * S + H / (i32)2) / H;
        i32 Hp = H + (H * r * (S + H) + (S * L) / (i32)2) / (S * L) + (r * L + S / (i32)2) / S;
        // The base also moves back by rim, so the rear corners stand proud of the shaft's own outline.
        i32 bx = cx - (ux * r) / (i32)256;
        i32 by = cy - (uy * r) / (i32)256;
        out.moveTo((i16)(bx + (nx * Hp) / (i32)256), (i16)(by + (ny * Hp) / (i32)256));
        out.lineTo((i16)(cx + (ux * Lp) / (i32)256), (i16)(cy + (uy * Lp) / (i32)256));
        out.lineTo((i16)(bx - (nx * Hp) / (i32)256), (i16)(by - (ny * Hp) / (i32)256));
        out.close();
        return out;
        }

    UXShapePath* capOutline(bool atStart, i16 width)
        {
        UXShapePath* out = new UXShapePath();
        i32 which = atStart ? startCap : endCap;
        if (which == (i32)UXCAP_NONE)
            {
            return out;
            }
        i32 w = (i32)(width > (i16)0 ? width : capWidth);
        if (w <= (i32)0)
            {
            return out;
            }
        i32 dx = (i32)0;
        i32 dy = (i32)0;
        i32 cx = (i32)0;
        i32 cy = (i32)0;
        if (!self.capDirection(atStart, &dx, &dy))
            {
            return out;
            }
        if (!self.capAnchor(atStart, &cx, &cy))
            {
            return out;
            }
        i32 len = UXGeom.length(dx, dy);
        if (len <= (i32)0)
            {
            return out;
            }
        // Unit outward and its perpendicular, at 1/256 precision — enough that a cap on a 16px
        // stroke lands within a pixel, and small enough that nothing here leaves i32.
        i32 ux = dx * (i32)256 / len;
        i32 uy = dy * (i32)256 / len;
        i32 nx = -uy;
        i32 ny = ux;
        i32 r = w / (i32)2;

        if (which == (i32)UXCAP_SQUARE)
            {
            out.moveTo((i16)(cx + (nx * r) / (i32)256), (i16)(cy + (ny * r) / (i32)256));
            out.lineTo((i16)(cx + (nx * r + ux * r) / (i32)256), (i16)(cy + (ny * r + uy * r) / (i32)256));
            out.lineTo((i16)(cx - (nx * r - ux * r) / (i32)256), (i16)(cy - (ny * r - uy * r) / (i32)256));
            out.lineTo((i16)(cx - (nx * r) / (i32)256), (i16)(cy - (ny * r) / (i32)256));
            out.close();
            return out;
            }
        if (which == (i32)UXCAP_ARROW)
            {
            // Tip along the direction of travel, base across it.  A base of one stroke width either
            // side reads as an arrow rather than a spike at any width worth drawing.
            i32 alen = (i32)arrowLen > (i32)0 ? (i32)arrowLen : w * (i32)5 / (i32)2;
            i32 half = w;
            out.moveTo((i16)(cx + (nx * half) / (i32)256), (i16)(cy + (ny * half) / (i32)256));
            out.lineTo((i16)(cx + (ux * alen) / (i32)256), (i16)(cy + (uy * alen) / (i32)256));
            out.lineTo((i16)(cx - (nx * half) / (i32)256), (i16)(cy - (ny * half) / (i32)256));
            out.close();
            return out;
            }
        // ROUND: a FULL disc, not the half-disc the cap strictly is.  The half is geometrically
        // right and visually wrong: its flat edge lands exactly on the end of the last stroke quad,
        // and two antialiased polygons sharing an edge each lay down a half-covered pixel along it,
        // so the two blends leave a seam drawn straight across the cap.  The far half of a full disc
        // is inside the stroke and invisible; the seam is not.
        xgArcInit();
        for (i32 k = (i32)0; k < (i32)8; k = k + (i32)1)
            {
            i32 ox = (gUXArcS[k] * ux - gUXArcC[k] * nx) * r / (i32)65536;
            i32 oy = (gUXArcS[k] * uy - gUXArcC[k] * ny) * r / (i32)65536;
            if (k == (i32)0)
                {
                out.moveTo((i16)(cx + ox), (i16)(cy + oy));
                }
            else
                {
                out.lineTo((i16)(cx + ox), (i16)(cy + oy));
                }
            }
        // the mirrored half turn
        for (i32 k = (i32)0; k < (i32)8; k = k + (i32)1)
            {
            i32 ox = -(gUXArcS[k] * ux - gUXArcC[k] * nx) * r / (i32)65536;
            i32 oy = -(gUXArcS[k] * uy - gUXArcC[k] * ny) * r / (i32)65536;
            out.lineTo((i16)(cx + ox), (i16)(cy + oy));
            }
        out.close();
        return out;
        }

    UXRect boundingBox(void)
        {
        if (curved)
            {
            return self.flattened().boundingBox();
            }
        i32 n = (i32)elements.count();
        bool any = false;
        i16 minx = (i16)0;
        i16 miny = (i16)0;
        i16 maxx = (i16)0;
        i16 maxy = (i16)0;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            UXPathElement* e = self.elemAt(i);
            if (e.type == (i32)UXPE_CLOSE)
                {
                continue;
                }
            if (!any)
                {
                minx = e.x;
                maxx = e.x;
                miny = e.y;
                maxy = e.y;
                any = true;
                }
            else
                {
                if (e.x < minx)
                    {
                    minx = e.x;
                    }
                if (e.x > maxx)
                    {
                    maxx = e.x;
                    }
                if (e.y < miny)
                    {
                    miny = e.y;
                    }
                if (e.y > maxy)
                    {
                    maxy = e.y;
                    }
                }
            }
        if (!any)
            {
            return UXGeom.zero();
            }
        return UXGeom.make(minx, miny, (i16)(maxx - minx), (i16)(maxy - miny));
        }

    // Build the edge list, implicitly closing every subpath.  Curves flatten first — an edge is a
    // straight segment by definition, and containment counts edge crossings.
    Array<UXEdge>* edges(void)
        {
        if (curved)
            {
            return self.flattened().edges();
            }
        Array<UXEdge>* out = new Array();
        i32 n = (i32)elements.count();
        i16 subX = (i16)0;
        i16 subY = (i16)0;
        i16 curX = (i16)0;
        i16 curY = (i16)0;
        bool open = false;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            UXPathElement* e = self.elemAt(i);
            if (e.type == (i32)UXPE_MOVE)
                {
                // close the previous subpath
                if (open)
                    {
                    self.addEdge(out, curX, curY, subX, subY);
                    }
                subX = e.x;
                subY = e.y;
                curX = e.x;
                curY = e.y;
                open = true;
                }
            else if (e.type == (i32)UXPE_LINE)
                {
                self.addEdge(out, curX, curY, e.x, e.y);
                curX = e.x;
                curY = e.y;
                }
            // CLOSE
            else
                {
                if (open)
                    {
                    self.addEdge(out, curX, curY, subX, subY);
                    curX = subX;
                    curY = subY;
                    open = false;
                    }
                }
            }
        // implicitly close the last
        if (open)
            {
            self.addEdge(out, curX, curY, subX, subY);
            }
        return out;
        }
    void addEdge(Array<UXEdge>* out, i16 x0, i16 y0, i16 x1, i16 y1)
        {
        if (x0 == x1 && y0 == y1)
            {
            return;
            }
        UXEdge* ed = new UXEdge();
        ed.x0 = x0;
        ed.y0 = y0;
        ed.x1 = x1;
        ed.y1 = y1;
        out.add(ed);
        }

    // Even-odd containment via a horizontal ray to +x, counting edge crossings.
    bool containsPoint(i16 px, i16 py)
        {
        Array<UXEdge>* es = self.edges();
        bool inside = false;
        for (u16 i = (u16)0; i < es.count(); i = i + (u16)1)
            {
            UXEdge* e = (UXEdge* ?)es.get(i);
            i32 y0 = (i32)e.y0;
            i32 y1 = (i32)e.y1;
            i32 x0 = (i32)e.x0;
            i32 x1 = (i32)e.x1;
            bool straddles = (y0 > (i32)py) != (y1 > (i32)py);
            if (straddles)
                {
                // x of the edge at scanline py:  x0 + (py-y0)*(x1-x0)/(y1-y0)
                i32 xcross = x0 + ((i32)py - y0) * (x1 - x0) / (y1 - y0);
                if ((i32)px < xcross)
                    {
                    inside = !inside;
                    }
                }
            }
        return inside;
        }
    }
