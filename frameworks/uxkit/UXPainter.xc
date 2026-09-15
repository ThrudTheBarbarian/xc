// UXPainter.xc — drawing VECTOR SHAPES through the neutral seam: stroke a path, fill a path, fill it
// with a radial gradient.
//
// This is the whole reason the seam is one primitive (fillPolygon) rather than a call per effect.
// Everything here happens ONCE, in neutral integer arithmetic, and every backend gets the result:
// a 16px stroke with a rounded start and an arrowhead is the same pixels on GEM, Win32 and AppKit,
// because it is the same polygons on all three.  The alternative — a strokePath seam call per
// backend — means VDI's odd-only line widths, GDI's geometric-pen joins and AppKit's line caps all
// disagreeing about a shape the app described once, and neither VDI nor GDI has an arrowhead at all.
//
// STROKING PRODUCES CONVEX PIECES, NOT ONE OUTLINE.  A quad per segment, a fan per join, a polygon
// per cap — drawn in sequence.  A true offset outline is a much harder problem (self-intersection on
// tight curves), and worse, a single path containing overlapping pieces cannot be filled EVEN-ODD
// without the overlaps cancelling to holes.  Overdrawing convex pieces in an opaque colour has
// neither problem and is what the fill rule difference between backends can never show through.
#import "UXShapePath.xc"
#import "UXGraphics.xc"
#import "UXGradient.xc"
#import "UXColor.xc"
#import "UXGeometry.xc"

// The flattened centreline of the path being stroked, in 1/16 px.
#define UX_FLAT_MAX 2000

// The op run handed to a native stroker: one opcode plus up to six coordinates per element.
#define UX_OPS_MAX 2048

class UXPainter
    {
    // A COLOUR here is either a VDI pen index (0..255, what the rest of the toolkit passes around) or
    // a packed true-colour value with bit 24 set.  One i32 rather than a pen argument AND three
    // colour arguments, because strokeSegment already takes seven and xtc's arm64 backend has a
    // history with arguments past the eighth — and because every call below would otherwise need a
    // duplicate.  UXPainter.rgb(r,g,b) builds one.
    // Divide with ROUNDING, for a positive divisor.  Truncation is what made a stroke look blocky:
    // the half-width normal was computed as (-dy*256/len)*r/256, truncating twice, so the width of
    // the quad varied by up to a pixel with the segment's direction and the silhouette wobbled from
    // segment to segment.  A curve is hundreds of short segments, so the wobble reads as lumpiness.
    static i32 divRound(i32 a, i32 b)
        {
        if (b == (i32)0)
            {
            return (i32)0;
            }
        return a >= (i32)0 ? (a + b / (i32)2) / b : -(((-a) + b / (i32)2) / b);
        }
    static i32 rgb(i32 r, i32 g, i32 b)
        {
        return (i32)$1000000 | (r << (i32)16) | (g << (i32)8) | b;
        }
    static bool isRGB(i32 c)
        {
        return (c & (i32)$1000000) != (i32)0;
        }

    // Hand one convex piece to the backend.  The scratch is a file-scope buffer rather than a local:
    // a stroke emits a piece per segment and this is on the hot path of every repaint.
    static void fillShape(UXGraphics* g, UXShapePath* p, i32 colour)
        {
        i32 n = UXPainter.flatten(p);
        if (n < (i32)3)
            {
            return;
            }
        if (UXPainter.isRGB(colour))
            {
            g.fillPolygonRGB(&gUXPaintXY[(i32)0], n, (colour >> (i32)16) & (i32)255,
                             (colour >> (i32)8) & (i32)255, colour & (i32)255);
            }
        else
            {
            g.fillPolygon(&gUXPaintXY[(i32)0], n, colour);
            }
        }
    static void fillShapeRGB(UXGraphics* g, UXShapePath* p, i32 r, i32 gr, i32 b)
        {
        i32 n = UXPainter.flatten(p);
        if (n >= (i32)3)
            {
            g.fillPolygonRGB(&gUXPaintXY[(i32)0], n, r, gr, b);
            }
        }
    // Copy a path's points into the flat x,y array the seam takes, flattening curves on the way.
    //
    // Through the SUB-PIXEL flattener and rounded exactly as the stroker rounds, which matters more
    // than it sounds: a filled shape and the stroke around it must agree on where their shared edge
    // is.  When the fill used the whole-pixel flattener and the stroke used the sub-pixel one, the
    // two disagreed by up to a pixel and left white crescents between a filled ball and its outline.
    static i32 flatten(UXShapePath* p)
        {
        i32 fxn = p.flattenFx(&gUXFlatFx[(i32)0], (i32)UX_FLAT_MAX);
        i32 n = (i32)0;
        for (i32 i = (i32)0; i < fxn && n < (i32)128; i = i + (i32)1)
            {
            i32 x = gUXFlatFx[i * (i32)2];
            if (x == (i32)UX_FX_MOVE || x == (i32)UX_FX_CLOSE)
                {
                continue;
                }
            gUXPaintXY[n * (i32)2] = (i16)UXPainter.fxToPx(x);
            gUXPaintXY[n * (i32)2 + (i32)1] = (i16)UXPainter.fxToPx(gUXFlatFx[i * (i32)2 + (i32)1]);
            n = n + (i32)1;
            }
        return n;
        }

    // 1/16 px -> whole pixels, rounded.  The ONE place the stroker converts units: everything from
    // the flattener to here is fx, and the name of every local says so.  (The previous attempt at
    // this converted inside strokeSegment AND strokeJoin, whose inputs had already been converted,
    // and drew join discs sixteen times too big.)
    static i32 fxToPx(i32 v)
        {
        return v >= (i32)0 ? (v + (i32)8) / (i32)16 : -(((-v) + (i32)8) / (i32)16);
        }

    // ---- stroking ----------------------------------------------------------------------------
    // One segment of the stroke: the quad the segment sweeps at the given width.
    // Every coordinate here is 1/16 px, including widthFx.  Working sub-pixel and rounding only the
    // finished quad is what keeps the silhouette smooth: rounding the CENTRELINE first makes each
    // vertex up to half a pixel wrong, with the error alternating, and the stroke comes out lumpy on
    // every backend — antialiased or not.
    static void strokeSegmentFx(UXGraphics* g, i32 x0, i32 y0, i32 x1, i32 y1, i32 widthFx, i32 colour)
        {
        i32 dx = x1 - x0;
        i32 dy = y1 - y0;
        if (dx == (i32)0 && dy == (i32)0)
            {
            return;
            }
        i32 len = UXGeom.length(dx, dy); // fx in, fx out: precise enough at this scale
        if (len <= (i32)0)
            {
            return;
            }
        i32 r = widthFx / (i32)2;
        i32 nx = UXPainter.divRound(-dy * r, len);
        i32 ny = UXPainter.divRound(dx * r, len);
        gUXPaintXY[(i32)0] = (i16)UXPainter.fxToPx(x0 + nx);
        gUXPaintXY[(i32)1] = (i16)UXPainter.fxToPx(y0 + ny);
        gUXPaintXY[(i32)2] = (i16)UXPainter.fxToPx(x1 + nx);
        gUXPaintXY[(i32)3] = (i16)UXPainter.fxToPx(y1 + ny);
        gUXPaintXY[(i32)4] = (i16)UXPainter.fxToPx(x1 - nx);
        gUXPaintXY[(i32)5] = (i16)UXPainter.fxToPx(y1 - ny);
        gUXPaintXY[(i32)6] = (i16)UXPainter.fxToPx(x0 - nx);
        gUXPaintXY[(i32)7] = (i16)UXPainter.fxToPx(y0 - ny);
        UXPainter.emit(g, (i32)4, colour);
        }
    static void strokeJoinFx(UXGraphics* g, i32 cx, i32 cy, i32 widthFx, i32 colour)
        {
        i32 r = widthFx / (i32)2;
        // under half a pixel of radius: nothing to fill
        if (r < (i32)UX_FX)
            {
            return;
            }
        xgArcInit();
        for (i32 k = (i32)0; k < (i32)8; k = k + (i32)1)
            {
            gUXPaintXY[k * (i32)2] = (i16)UXPainter.fxToPx(cx + UXPainter.divRound(gUXArcC[k] * r, (i32)256));
            gUXPaintXY[k * (i32)2 + (i32)1] = (i16)UXPainter.fxToPx(cy + UXPainter.divRound(gUXArcS[k] * r, (i32)256));
            gUXPaintXY[((i32)8 + k) * (i32)2] = (i16)UXPainter.fxToPx(cx - UXPainter.divRound(gUXArcC[k] * r, (i32)256));
            gUXPaintXY[((i32)8 + k) * (i32)2 + (i32)1] = (i16)UXPainter.fxToPx(cy - UXPainter.divRound(gUXArcS[k] * r, (i32)256));
            }
        // The two halves were filled in interleaved order above; reorder into one ring.
        i16 tmp[32];
        for (i32 k = (i32)0; k < (i32)32; k = k + (i32)1)
            {
            tmp[k] = gUXPaintXY[k];
            }
        for (i32 k = (i32)0; k < (i32)8; k = k + (i32)1)
            {
            gUXPaintXY[k * (i32)2] = tmp[k * (i32)2];
            gUXPaintXY[k * (i32)2 + (i32)1] = tmp[k * (i32)2 + (i32)1];
            gUXPaintXY[((i32)8 + k) * (i32)2] = tmp[((i32)8 + k) * (i32)2];
            gUXPaintXY[((i32)8 + k) * (i32)2 + (i32)1] = tmp[((i32)8 + k) * (i32)2 + (i32)1];
            }
        UXPainter.emit(g, (i32)16, colour);
        }
    // Hand the scratch to the seam in whichever colour form was asked for.
    static void emit(UXGraphics* g, i32 n, i32 colour)
        {
        if (n < (i32)3)
            {
            return;
            }
        if (UXPainter.isRGB(colour))
            {
            g.fillPolygonRGB(&gUXPaintXY[(i32)0], n, (colour >> (i32)16) & (i32)255,
                             (colour >> (i32)8) & (i32)255, colour & (i32)255);
            }
        else
            {
            g.fillPolygon(&gUXPaintXY[(i32)0], n, colour);
            }
        }

    static void strokeSegment(UXGraphics* g, i32 x0, i32 y0, i32 x1, i32 y1, i16 width, i32 colour)
        {
        i32 dx = x1 - x0;
        i32 dy = y1 - y0;
        if (dx == (i32)0 && dy == (i32)0)
            {
            return;
            }
        i32 r = (i32)width / (i32)2;
        // The normal at half the width.  The LENGTH is taken at 16x precision, which matters far
        // more than it looks: UXGeom.length floors, and flattening now produces segments only a few
        // pixels long, where flooring 2.236 to 2 inflates the normal by ten per cent.  Every such
        // segment then draws a quad a pixel too wide in its own direction, and a curve made of
        // hundreds of them grows a spike at each one — the silhouette came out visibly ragged.
        // (dx,dy are one flattened segment, so dx*dx*256 has an order of magnitude of headroom.)
        i32 len16 = UXGeom.isqrt((dx * dx + dy * dy) * (i32)256);
        if (len16 <= (i32)0)
            {
            return;
            }
        i32 nx = UXPainter.divRound(-dy * r * (i32)16, len16);
        i32 ny = UXPainter.divRound(dx * r * (i32)16, len16);
        // No overhang past the ends.  An earlier version stretched every quad a pixel along its own
        // direction so consecutive quads would overlap rather than abut (an abutting pair leaves an
        // antialiased seam).  It works, but it pokes a pixel past EVERY vertex of a flattened curve,
        // and hundreds of one-pixel spurs read as a bumpy, faceted silhouette.  The join disc drawn
        // at each vertex already overlaps both quads and covers the seam, so the overhang bought
        // nothing and cost the smoothness this whole slice is about.
        UXShapePath* q = new UXShapePath();
        q.moveTo((i16)(x0 + nx), (i16)(y0 + ny));
        q.lineTo((i16)(x1 + nx), (i16)(y1 + ny));
        q.lineTo((i16)(x1 - nx), (i16)(y1 - ny));
        q.lineTo((i16)(x0 - nx), (i16)(y0 - ny));
        q.close();
        UXPainter.fillShape(g, q, colour);
        }
    // A round join: a disc at an interior vertex, filling the wedge two quads leave open.  Round
    // because it is the only join that is correct at every angle without a miter limit, and because
    // it costs one polygon rather than a case analysis.
    static void strokeJoin(UXGraphics* g, i32 cx, i32 cy, i16 width, i32 colour)
        {
        i32 r = (i32)width / (i32)2;
        // Only a ZERO-radius join can be skipped.  This used to skip r < 2 on the theory that at
        // hairline widths the quads already meet — they do not: consecutive quads meet at an angle
        // and leave a notch on the outside of every turn, so a 3px outline round a curve came out
        // visibly polygonal, which read as the CURVE being faceted rather than its outline.
        if (r < (i32)1)
            {
            return;
            }
        UXShapePath* d = new UXShapePath();
        xgArcInit();
        // EXACTLY the stroke's half width, rounded.  An earlier version circumscribed the disc
        // (x261/256, so its flats rather than its corners sat on the circle) to guarantee it covered
        // the quad's end edge.  That is 2% oversize, which is nothing on ONE join — but a flattened
        // curve has a join at every vertex, and a chain of hundreds of slightly-too-big discs turns
        // the silhouette into a row of bumps.  Rounding the vertices is enough; the sub-pixel dip
        // between them does not reach the edge of a quad.
        for (i32 k = (i32)0; k < (i32)8; k = k + (i32)1)
            {
            i32 ox = UXPainter.divRound(gUXArcC[k] * r, (i32)256);
            i32 oy = UXPainter.divRound(gUXArcS[k] * r, (i32)256);
            if (k == (i32)0)
                {
                d.moveTo((i16)(cx + ox), (i16)(cy + oy));
                }
            else
                {
                d.lineTo((i16)(cx + ox), (i16)(cy + oy));
                }
            }
        // The arc table is a half turn; mirror it for the other half rather than carrying 16 entries.
        for (i32 k = (i32)0; k < (i32)8; k = k + (i32)1)
            {
            i32 ox = -UXPainter.divRound(gUXArcC[k] * r, (i32)256);
            i32 oy = -UXPainter.divRound(gUXArcS[k] * r, (i32)256);
            d.lineTo((i16)(cx + ox), (i16)(cy + oy));
            }
        d.close();
        UXPainter.fillShape(g, d, colour);
        }

    // Encode a path as the op run strokeNative takes — curves INTACT, because handing over the
    // flattening would throw away the very thing a native stroker is being used for.
    static i32 encodeOps(UXShapePath* p)
        {
        i32 n = (i32)0;
        for (i32 i = (i32)0; i < p.elementCount(); i = i + (i32)1)
            {
            UXPathElement* e = p.elemAt(i);
            if (n + (i32)7 > (i32)UX_OPS_MAX)
                {
                break;
                }
            if (e.type == (i32)UXPE_CLOSE)
                {
                gUXOps[n] = (i32)UXSTROKE_CLOSE;
                n = n + (i32)1;
                }
            else if (e.type == (i32)UXPE_CURVE)
                {
                gUXOps[n] = (i32)UXSTROKE_CURVE;
                n = n + (i32)1;
                gUXOps[n] = (i32)e.c1x;
                gUXOps[n + (i32)1] = (i32)e.c1y;
                gUXOps[n + (i32)2] = (i32)e.c2x;
                gUXOps[n + (i32)3] = (i32)e.c2y;
                gUXOps[n + (i32)4] = (i32)e.x;
                gUXOps[n + (i32)5] = (i32)e.y;
                n = n + (i32)6;
                }
            else
                {
                gUXOps[n] = e.type == (i32)UXPE_MOVE ? (i32)UXSTROKE_MOVE : (i32)UXSTROKE_LINE;
                n = n + (i32)1;
                gUXOps[n] = (i32)e.x;
                gUXOps[n + (i32)1] = (i32)e.y;
                n = n + (i32)2;
                }
            }
        return n;
        }
    // A cap the BACKEND can do.  Round and square it has; an arrowhead it does not, and a butt end is
    // what an arrowhead should sit on, so ARROW is passed down as NONE and drawn as a shape.
    static i32 nativeCap(i32 cap)
        {
        return cap == (i32)UXCAP_ARROW ? (i32)UXCAP_NONE : cap;
        }

    // Stroke `p` at `width`, honouring its caps.  The path flattens first, so a curve strokes as the
    // polyline it approximates — which is exactly what makes the result identical on every backend.
    static void strokePath(UXGraphics* g, UXShapePath* p, i16 width, i32 colour)
        {
        // Where the backend strokes, let it: it draws the CURVE at sub-pixel precision with its own
        // joins, which the neutral stroker cannot — it offsets a polyline whose vertices are whole
        // pixels, so its silhouette wobbles by up to half a pixel and looks lumpy wherever something
        // antialiases.  Arrowheads are still ours (no backend has one), and so is GEM entirely.
        if (g.strokesNatively())
            {
            i32 n = UXPainter.encodeOps(p);
            if (n > (i32)0)
                {
                i32 sc = UXPainter.nativeCap(p.startCapKind());
                i32 ec = UXPainter.nativeCap(p.endCapKind());
                if (UXPainter.isRGB(colour))
                    {
                    g.strokeNativeRGB(&gUXOps[(i32)0], n, (i32)width, sc, ec,
                                      (colour >> (i32)16) & (i32)255,
                                      (colour >> (i32)8) & (i32)255, colour & (i32)255);
                    }
                else
                    {
                    g.strokeNative(&gUXOps[(i32)0], n, (i32)width, sc, ec, colour);
                    }
                }
            UXShapePath* a0 = p.capOutline(true, width);
            if (a0.elementCount() > (i32)0 && p.startCapKind() == (i32)UXCAP_ARROW)
                {
                UXPainter.fillShape(g, a0, colour);
                }
            UXShapePath* a1 = p.capOutline(false, width);
            if (a1.elementCount() > (i32)0 && p.endCapKind() == (i32)UXCAP_ARROW)
                {
                UXPainter.fillShape(g, a1, colour);
                }
            return;
            }
        // The neutral stroker, for GEM.  The centreline comes back in 1/16 px and stays there until
        // each finished quad or disc is rounded — see strokeSegmentFx.
        i32 widthFx = (i32)width * (i32)UX_FX;
        i32 n = p.flattenFx(&gUXFlatFx[(i32)0], (i32)UX_FLAT_MAX);
        i32 px = (i32)0;
        i32 py = (i32)0;
        bool have = false;
        i32 sx = (i32)0;
        i32 sy = (i32)0; // subpath start, for CLOSE
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            i32 ex = gUXFlatFx[i * (i32)2];
            i32 ey = gUXFlatFx[i * (i32)2 + (i32)1];
            if (ex == (i32)UX_FX_MOVE)
                {
                i = i + (i32)1;
                if (i >= n)
                    {
                    break;
                    }
                px = gUXFlatFx[i * (i32)2];
                py = gUXFlatFx[i * (i32)2 + (i32)1];
                sx = px;
                sy = py;
                have = true;
                continue;
                }
            if (ex == (i32)UX_FX_CLOSE)
                {
                if (have)
                    {
                    UXPainter.strokeSegmentFx(g, px, py, sx, sy, widthFx, colour);
                    px = sx;
                    py = sy;
                    }
                continue;
                }
            if (!have)
                {
                px = ex;
                py = ey;
                have = true;
                continue;
                }
            UXPainter.strokeSegmentFx(g, px, py, ex, ey, widthFx, colour);
            // Join at the vertex we just arrived at, unless it is the very last point of an open
            // path — that one belongs to the cap.
            if (i + (i32)1 < n)
                {
                UXPainter.strokeJoinFx(g, ex, ey, widthFx, colour);
                }
            px = ex;
            py = ey;
            }
        // The caps are shapes like any other; capOutline already knows the tangent and the width.
        UXShapePath* c0 = p.capOutline(true, width);
        if (c0.elementCount() > (i32)0)
            {
            UXPainter.fillShape(g, c0, colour);
            }
        UXShapePath* c1 = p.capOutline(false, width);
        if (c1.elementCount() > (i32)0)
            {
            UXPainter.fillShape(g, c1, colour);
            }
        }

    // Stroke with an OUTLINE: the shape in `fill`, ringed by `rim` pixels of `outline`.  Two passes,
    // but the wide pass has to be a UNIFORM DILATION of the narrow one or the ring is not uniform —
    // and an arrowhead's length is proportional to the stroke width, so simply stroking twice at
    // different widths makes the outline arrow 2.5x rim LONGER as well as wider.  That is why the
    // demo showed a fat black spike at the tip and no outline at all behind the head.  Setting the
    // arrow length explicitly for each pass dilates it by exactly rim, like every other edge.
    static void strokeOutlined(UXGraphics* g, UXShapePath* p, i16 width, i32 fill, i32 outline, i16 rim)
        {
        i32 sc = p.startCapKind();
        i32 ec = p.endCapKind();
        // The wide pass draws the body and any cap that DILATES correctly — a disc grown by rim is
        // still the right disc, a wider quad is still the right quad.  An ARROWHEAD does not: a
        // bigger similar triangle is not an offset one.  Its rim pinches to nothing at the tip
        // (which is why the outline looked like a second triangle rather than a line of even
        // thickness) and vanishes entirely across the rear edge, because both triangles share that
        // edge.  So the arrow is suppressed here and outlined properly below.
        if (sc == (i32)UXCAP_ARROW)
            {
            p.setStartCap((i32)UXCAP_NONE);
            }
        if (ec == (i32)UXCAP_ARROW)
            {
            p.setEndCap((i32)UXCAP_NONE);
            }
        UXPainter.strokePath(g, p, (i16)((i32)width + (i32)2 * (i32)rim), outline);
        p.setStartCap(sc);
        p.setEndCap(ec);

        // The arrowhead's outline is a FILLED, truly OFFSET triangle drawn under the fill — see
        // capOutlineRim.  Filling a dilated shape rather than stroking the outline of the real one
        // is what keeps the rim outside the shape entirely: stroking straddles the edge, so half the
        // rim lands inside and shows through wherever the fill does not quite reach.
        if (sc == (i32)UXCAP_ARROW)
            {
            UXPainter.fillShape(g, p.capOutlineRim(true, width, rim), outline);
            }
        if (ec == (i32)UXCAP_ARROW)
            {
            UXPainter.fillShape(g, p.capOutlineRim(false, width, rim), outline);
            }
        UXPainter.strokePath(g, p, width, fill);
        }

    // ---- fills -------------------------------------------------------------------------------
    // A copy of `p` shrunk toward (cx,cy) by num/den.  The building block of the radial fill.
    static UXShapePath* shrunk(UXShapePath* p, i32 cx, i32 cy, i32 num, i32 den)
        {
        UXShapePath* f = p.flattened();
        UXShapePath* out = new UXShapePath();
        for (i32 i = (i32)0; i < f.elementCount(); i = i + (i32)1)
            {
            UXPathElement* e = f.elemAt(i);
            if (e.type == (i32)UXPE_CLOSE)
                {
                out.close();
                continue;
                }
            i32 x = cx + ((i32)e.x - cx) * num / den;
            i32 y = cy + ((i32)e.y - cy) * num / den;
            out.add(e.type, (i16)x, (i16)y);
            }
        return out;
        }

    // CENTRE-TO-EDGE gradient fill: draw the shape in the outermost colour, then a stack of
    // progressively smaller copies through to the centre colour.  Neutral on purpose — only AppKit
    // has a radial gradient primitive (NSGradient drawInBezierPath:relativeCenterPosition:), GDI's
    // GradientFill is linear-only and VDI has nothing, so a native path would mean one backend
    // looking different from the other two.  Bands are the honest name for what this is: 24 is
    // smooth at widget size, and the cost is 24 polygon fills rather than a per-pixel sweep.
    static void fillShapeRadial(UXGraphics* g, UXShapePath* p, UXGradient* grad, i32 bands)
        {
        if (bands < (i32)2)
            {
            bands = (i32)2;
            }
        if (bands > (i32)64)
            {
            bands = (i32)64;
            }
        UXRect bb = p.boundingBox();
        i32 cx = (i32)bb.x + (i32)bb.w / (i32)2;
        i32 cy = (i32)bb.y + (i32)bb.h / (i32)2;
        for (i32 b = (i32)0; b < bands; b = b + (i32)1)
            {
            // b = 0 is the full-size outermost band, b = bands-1 the smallest at the centre.  The
            // gradient is sampled at the EDGE for the outermost, so stop 0 is the centre colour.
            i32 t = (i32)255 - (i32)255 * b / (bands - (i32)1);
            UXColor* c = grad.colorAt(t);
            UXShapePath* ring = b == (i32)0 ? p : UXPainter.shrunk(p, cx, cy, bands - b, bands);
            UXPainter.fillShapeRGB(g, ring, (i32)c.r, (i32)c.g, (i32)c.b);
            }
        }
    }

    // The flat x,y scratch the seam is handed.  128 points matches the ceiling libGEM's v_fillarea
    // imposes, so a shape that draws on one backend draws on all of them.
    i16 gUXPaintXY[256];
i32 gUXOps[2048];
i32 gUXFlatFx[4000];
