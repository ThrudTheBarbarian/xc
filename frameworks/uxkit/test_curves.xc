// test_curves.xc — cubic/quadratic curves in UXShapePath, flattening, and stroke caps.
//
// All pure geometry, so it runs headless on every arch with no driver.  The assertions are
// INVARIANTS rather than magic coordinates: a flattened curve must stay inside the hull its control
// points define, must start and end exactly on its anchors, must get finer when the curve gets
// bigger, and must be the same on every backend because the arithmetic is integer.  A test full of
// expected pixel values would pass on one flattener and have to be rewritten for the next.
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

// The last on-curve point of a path.
void lastPoint(UXShapePath* p, i32* ox, i32* oy)
    {
    i32 n = p.elementCount();
    for (i32 i = (i32)0; i < n; i = i + (i32)1)
        {
        UXPathElement* e = p.elemAt(i);
        if (e.type != (i32)UXPE_CLOSE)
            {
            ox[(i32)0] = (i32)e.x;
            oy[(i32)0] = (i32)e.y;
            }
        }
    }
// Greatest distance of any point of `p` from the straight chord a->b.  For a flattened curve this
// says how far the approximation wandered; for the chord itself it is 0.
i32 maxDeviation(UXShapePath* p, i32 ax, i32 ay, i32 bx, i32 by)
    {
    i32 dx = bx - ax;
    i32 dy = by - ay;
    i32 len = UXGeom.length(dx, dy);
    if (len <= (i32)0)
        {
        return (i32)0;
        }
    i32 worst = (i32)0;
    for (i32 i = (i32)0; i < p.elementCount(); i = i + (i32)1)
        {
        UXPathElement* e = p.elemAt(i);
        if (e.type == (i32)UXPE_CLOSE)
            {
            continue;
            }
        i32 c = dx * ((i32)e.y - ay) - dy * ((i32)e.x - ax);
        if (c < (i32)0)
            {
            c = -c;
            }
        i32 d = c / len;
        if (d > worst)
            {
            worst = d;
            }
        }
    return worst;
    }

void main(void)
    {
    gFails = (i32)0;

    // ---- a cubic flattens into lines, on its anchors -------------------------------------------
    UXShapePath* c = new UXShapePath();
    c.moveTo((i16)0, (i16)0);
    c.curveTo((i16)0, (i16)100, (i16)100, (i16)100, (i16)100, (i16)0);
    checkTrue("a curve reports itself curved", c.hasCurves());
    check("stored as two elements, curve intact", c.elementCount(), (i32)2);

    UXShapePath* f = c.flattened();
    checkTrue("flattening produced more than the two anchors", f.elementCount() > (i32)2);
    checkTrue("the flattened path has no curves left", !f.hasCurves());
    UXPathElement* first = f.elemAt((i32)0);
    check("starts exactly on the first anchor (x)", (i32)first.x, (i32)0);
    check("...and (y)", (i32)first.y, (i32)0);
    i32 lx = (i32)0;
    i32 ly = (i32)0;
    lastPoint(f, &lx, &ly);
    check("ends exactly on the last anchor (x)", lx, (i32)100);
    check("...and (y)", ly, (i32)0);

    // Every flattened point lies inside the control hull — for this symmetric curve, between the
    // baseline and the controls.  A flattener that overshoots is the classic subdivision bug.
    bool inHull = true;
    for (i32 i = (i32)0; i < f.elementCount(); i = i + (i32)1)
        {
        UXPathElement* e = f.elemAt(i);
        if (e.x < (i16)0 || e.x > (i16)100 || e.y < (i16)0 || e.y > (i16)100)
            {
            inHull = false;
            }
        }
    checkTrue("every flattened point is inside the control hull", inHull);
    // ...and it actually bulges: a flattener that emitted one chord would pass everything above.
    checkTrue("the curve is not just its chord", maxDeviation(f, (i32)0, (i32)0, (i32)100, (i32)0) > (i32)10);

    // ---- the bounding box is the SHAPE's, not the control polygon's -----------------------------
    // The controls sit at y=100 but a cubic only reaches 3/4 of the way to them, so a box measured
    // from the stored elements would be too tall — and an over-reported box over-invalidates.
    UXRect bb = c.boundingBox();
    checkTrue("the box does not reach the control points", (i32)bb.h < (i32)100);
    checkTrue("...but does cover the real bulge", (i32)bb.h > (i32)60);
    check("the box spans the anchors horizontally", (i32)bb.w, (i32)100);

    // ---- a bigger curve gets MORE segments (adaptive, not fixed-step) --------------------------
    UXShapePath* big = new UXShapePath();
    big.moveTo((i16)0, (i16)0);
    big.curveTo((i16)0, (i16)1000, (i16)1000, (i16)1000, (i16)1000, (i16)0);
    checkTrue("a 10x bigger curve flattens to more segments",
              big.flattened().elementCount() > f.elementCount());
    // A straight "curve" — controls on the chord — must NOT be subdivided at all.
    UXShapePath* straight = new UXShapePath();
    straight.moveTo((i16)0, (i16)0);
    straight.curveTo((i16)30, (i16)0, (i16)60, (i16)0, (i16)90, (i16)0);
    check("a flat cubic collapses to a single line", straight.flattened().elementCount(), (i32)2);

    // ---- quadratics are elevated to the same cubic ----------------------------------------------
    UXShapePath* q = new UXShapePath();
    q.moveTo((i16)0, (i16)0);
    q.quadTo((i16)50, (i16)100, (i16)100, (i16)0);
    UXShapePath* qf = q.flattened();
    i32 qx = (i32)0;
    i32 qy = (i32)0;
    lastPoint(qf, &qx, &qy);
    check("a quadratic ends on its anchor (x)", qx, (i32)100);
    check("...and (y)", qy, (i32)0);
    // A quadratic peaks at half its control height; the elevation must preserve that.
    UXRect qb = q.boundingBox();
    checkTrue("the quadratic peaks near half its control height",
              (i32)qb.h >= (i32)45 && (i32)qb.h <= (i32)55);

    // ---- containment still works through a curve ------------------------------------------------
    UXShapePath* blob = new UXShapePath();
    blob.moveTo((i16)0, (i16)0);
    blob.curveTo((i16)0, (i16)80, (i16)100, (i16)80, (i16)100, (i16)0);
    blob.close();
    checkTrue("a point under the arch is inside", blob.containsPoint((i16)50, (i16)20));
    checkTrue("a point above the arch is outside", blob.containsPoint((i16)50, (i16)70) == false);

    // The analytic tangents, directly.  An S-curve, deliberately ASYMMETRIC so the two ends give
    // genuinely different answers — a symmetric arch has both tangents parallel and would pass even
    // if the two cases were swapped.  It sets off rightward and arrives rightward, so the OUTWARD
    // directions are: at the start, back to the left (p0 - c1); at the end, onward to the right
    // (p3 - c2).
    UXShapePath* tang = new UXShapePath();
    tang.moveTo((i16)0, (i16)0);
    tang.curveTo((i16)50, (i16)0, (i16)50, (i16)100, (i16)100, (i16)100);
    i32 tdx = (i32)0;
    i32 tdy = (i32)0;
    checkTrue("an end tangent exists", tang.capDirection(false, &tdx, &tdy));
    checkTrue("it points on along the travel (+x, level)", tdx > (i32)0 && tdy == (i32)0);
    checkTrue("a start tangent exists", tang.capDirection(true, &tdx, &tdy));
    checkTrue("...and the start one points back the other way (-x, level)", tdx < (i32)0 && tdy == (i32)0);

    // ---- caps ------------------------------------------------------------------------------------
    // A 16px stroke, rounded where it starts and an arrowhead where it ends — the shape asked for.
    UXShapePath* stroke = new UXShapePath();
    stroke.moveTo((i16)100, (i16)100);
    stroke.curveTo((i16)100, (i16)0, (i16)300, (i16)0, (i16)300, (i16)100);
    stroke.setStartCap((i32)UXCAP_ROUND);
    stroke.setEndCap((i32)UXCAP_ARROW);
    stroke.setCapWidth((i16)16);

    UXShapePath* head = stroke.capOutline(false, (i16)16);
    check("the arrowhead is a triangle", head.elementCount(), (i32)4); // 3 points + close
    // It must point the way the curve was GOING — this curve arrives heading straight down (+y),
    // so the tip is below the endpoint and the base straddles it horizontally.
    i32 tipx = (i32)head.elemAt((i32)1).x;
    i32 tipy = (i32)head.elemAt((i32)1).y;
    checkTrue("the arrow tip is beyond the endpoint, along the travel", tipy > (i32)100);
    // EXACTLY on the axis, not merely near it.  This curve arrives with tangent p3-c2 = (0,100),
    // dead vertical, so the tip must share the endpoint's x to the pixel.  Reading the direction off
    // the flattened polyline instead gives the last CHORD — (3,19) here, about 9 degrees off — and
    // the arrowhead hangs askew.  A tolerance of +-5 accepted that; this does not.
    check("...and exactly on the curve's axis", tipx, (i32)300);
    i32 b1x = (i32)head.elemAt((i32)0).x;
    i32 b2x = (i32)head.elemAt((i32)2).x;
    checkTrue("the base straddles the endpoint", (b1x - (i32)300) * (b2x - (i32)300) < (i32)0);

    UXShapePath* cap = stroke.capOutline(true, (i16)16);
    // A FULL disc (16 points + close), not the half-disc a cap strictly is.  The half's flat edge
    // lands exactly on the end of the last stroke quad, and two antialiased polygons sharing an edge
    // leave a seam blended straight across the cap — visible on AppKit, invisible on GEM.  The far
    // half is inside the stroke and costs nothing.
    check("the round cap is a full disc", cap.elementCount(), (i32)17);
    // Every point of a round cap is the same distance from the anchor: that IS the definition, and
    // it is what a rotation-accumulated arc gets wrong.
    bool onCircle = true;
    for (i32 i = (i32)0; i < cap.elementCount(); i = i + (i32)1)
        {
        UXPathElement* e = cap.elemAt(i);
        if (e.type == (i32)UXPE_CLOSE)
            {
            continue;
            }
        i32 d = UXGeom.length((i32)e.x - (i32)100, (i32)e.y - (i32)100);
        // radius 8, +-1 for integer rounding
        if (d < (i32)7 || d > (i32)8)
            {
            onCircle = false;
            }
        }
    checkTrue("every round-cap point sits on the half-width circle", onCircle);
    // The start curve leaves heading up (-y), so the cap must bulge DOWNWARD, away from the path.
    i32 below = (i32)0;
    for (i32 i = (i32)0; i < cap.elementCount(); i = i + (i32)1)
        {
        UXPathElement* e = cap.elemAt(i);
        if (e.type != (i32)UXPE_CLOSE && (i32)e.y > (i32)100)
            {
            below = below + (i32)1;
            }
        }
    checkTrue("the round cap bulges away from the path", below >= (i32)3);
    // ...and, being a full disc, reaches back INTO the stroke as well — that half is what covers the
    // quad's end edge instead of abutting it.
    i32 above = (i32)0;
    for (i32 i = (i32)0; i < cap.elementCount(); i = i + (i32)1)
        {
        UXPathElement* e = cap.elemAt(i);
        if (e.type != (i32)UXPE_CLOSE && (i32)e.y < (i32)100)
            {
            above = above + (i32)1;
            }
        }
    checkTrue("...and also covers the stroke side", above >= (i32)3);

    // No cap asked for, no geometry produced — the default must cost nothing.
    UXShapePath* plain = new UXShapePath();
    plain.moveTo((i16)0, (i16)0);
    plain.lineTo((i16)50, (i16)0);
    check("UXCAP_NONE produces an empty shape", plain.capOutline(false, (i16)16).elementCount(), (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXShapePath — cubics, quadratics, adaptive flattening, caps.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
