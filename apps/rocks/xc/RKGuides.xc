// RKGuides.xc — alignment guides and snapping.
//
// Pure geometry: rectangles in, an adjusted rectangle and a list of guide
// lines out.  No widgets, no driver, no model — which is the point, because
// snapping is the part of direct manipulation most likely to be subtly wrong
// (off by one, sticking to the wrong edge, sticking when it should not) and
// the part hardest to check by hand while dragging a mouse.
//
// WHAT IT SNAPS TO, and why these and not more: a sibling's left/centre/right
// and top/middle/bottom, plus the same six on the parent.  Those are the lines
// a designer is actually trying to hit — controls lined up with each other, or
// centred in the form.  A pixel grid is deliberately NOT included: on a GEM
// resource the useful alignment is to other objects, and a grid would fight
// the character-cell coordinates the format already rounds to.
//
// The threshold applies to the DISTANCE, so a drag never jumps more than
// RK_SNAP px — snapping should feel like a magnet, not like the object being
// taken away from you.
#import "Array.xc"
#import "UXGeometry.xc"

#define RK_SNAP 6 // how close an edge must be before it sticks

// A boxed integer, so candidate lines can live in an Array.
class RKInt : Object
    {
    i32 v;
    void init(void)
        {
        v = (i32)0;
        }
    static RKInt* of(i32 x)
        {
        RKInt* n = new RKInt();
        n.v = x;
        return n;
        }
    }

    // A boxed rectangle, so sibling frames can live in an Array.
    class RKRectBox : Object
    {
    UXRect r;
    void init(void)
        {
        r = UXGeom.zero();
        }
    static RKRectBox* of(UXRect x)
        {
        RKRectBox* b = new RKRectBox();
        b.r = x;
        return b;
        }
    }

    // A line the canvas draws while a drag is snapped to it.
    class RKGuide : Object
    {
    i32 pos; // x for a vertical line, y for a horizontal one
    bool vertical;
    void init(void)
        {
        pos = (i32)0;
        vertical = true;
        }
    static RKGuide* make(i32 p, bool vert)
        {
        RKGuide* g = new RKGuide();
        g.pos = p;
        g.vertical = vert;
        return g;
        }
    }

    class RKGuides : Object
    {

    // The three interesting positions of a span: leading edge, centre, trailing.
    static void edgesOf(i32 lo, i32 size, i32* a, i32* b, i32* c)
        {
        a[0] = lo;
        b[0] = lo + size / (i32)2;
        c[0] = lo + size;
        }

    // Snap one axis.  `lines` are candidate positions; `lo`/`size` describe the
    // moving rect on that axis.  Returns the adjusted `lo`, and sets `hit` to
    // the line snapped to, or -1 when nothing was near enough.
    //
    // The NEAREST candidate wins across all three edges rather than testing
    // leading-then-centre-then-trailing in order: a rect whose right edge is
    // 1px from one line and whose left edge is 5px from another must stick to
    // the right one, and a first-match rule would pick the wrong line.
    static i32 snapAxis(i32 lo, i32 size, Array<RKInt>* lines, i32 thr, i32* hit)
        {
        i32 bestDelta = thr + (i32)1;
        i32 bestLine = (i32)-1;
        i32 bestAdj = lo;
        i32 e0 = (i32)0;
        i32 e1 = (i32)0;
        i32 e2 = (i32)0;
        RKGuides.edgesOf(lo, size, &e0, &e1, &e2);
        for (i32 i = (i32)0; i < (i32)lines.count(); i = i + (i32)1)
            {
            i32 L = ((RKInt* ?)lines.get((u16)i)).v;
            i32 d = L - e0;
            if (d < (i32)0)
                {
                d = -d;
                }
            if (d < bestDelta)
                {
                bestDelta = d;
                bestLine = L;
                bestAdj = L;
                }
            d = L - e1;
            if (d < (i32)0)
                {
                d = -d;
                }
            if (d < bestDelta)
                {
                bestDelta = d;
                bestLine = L;
                bestAdj = L - size / (i32)2;
                }
            d = L - e2;
            if (d < (i32)0)
                {
                d = -d;
                }
            if (d < bestDelta)
                {
                bestDelta = d;
                bestLine = L;
                bestAdj = L - size;
                }
            }
        if (bestLine < (i32)0 || bestDelta > thr)
            {
            hit[0] = (i32)-1;
            return lo;
            }
        hit[0] = bestLine;
        return bestAdj;
        }

    static void linesOf(i32 lo, i32 size, Array<RKInt>* out)
        {
        out.add(RKInt.of(lo));
        out.add(RKInt.of(lo + size / (i32)2));
        out.add(RKInt.of(lo + size));
        }

    // ---- the rect-level entry point ----------------------------------------
    // With `enabled` false this returns `r` untouched and adds no guides, so a
    // caller has ONE code path whether snapping is on or off — the toggle
    // changes behaviour here rather than at every call site.
    static UXRect snapMove(UXRect r, Array<RKRectBox>* siblings, UXRect parent,
                           bool enabled, Array<RKGuide>* guides)
        {
        if (!enabled)
            {
            return r;
            }
        Array<RKInt>* vs = new Array();
        Array<RKInt>* hs = new Array();
        RKGuides.linesOf((i32)parent.x, (i32)parent.w, vs);
        RKGuides.linesOf((i32)parent.y, (i32)parent.h, hs);
        for (i32 i = (i32)0; i < (i32)siblings.count(); i = i + (i32)1)
            {
            UXRect s = ((RKRectBox* ?)siblings.get((u16)i)).r;
            RKGuides.linesOf((i32)s.x, (i32)s.w, vs);
            RKGuides.linesOf((i32)s.y, (i32)s.h, hs);
            }
        i32 hitX = (i32)-1;
        i32 hitY = (i32)-1;
        i32 nx = RKGuides.snapAxis((i32)r.x, (i32)r.w, vs, (i32)RK_SNAP, &hitX);
        i32 ny = RKGuides.snapAxis((i32)r.y, (i32)r.h, hs, (i32)RK_SNAP, &hitY);
        // `guides` is always a real array — a generic null (Array<T>*)0 does
        // not parse, and a caller that does not want them can simply ignore
        // what it is handed.
        if (hitX >= (i32)0)
            {
            guides.add(RKGuide.make(hitX, true));
            }
        if (hitY >= (i32)0)
            {
            guides.add(RKGuide.make(hitY, false));
            }
        return UXGeom.make((i16)nx, (i16)ny, r.w, r.h);
        }

    // Resizing moves the trailing edges only, so the leading corner is fixed
    // and only the size is snapped.  Kept separate from snapMove because a
    // resize that also moved the origin would fight the handle being dragged.
    static UXRect snapResize(UXRect r, Array<RKRectBox>* siblings, UXRect parent,
                             bool enabled, Array<RKGuide>* guides)
        {
        if (!enabled)
            {
            return r;
            }
        Array<RKInt>* vs = new Array();
        Array<RKInt>* hs = new Array();
        RKGuides.linesOf((i32)parent.x, (i32)parent.w, vs);
        RKGuides.linesOf((i32)parent.y, (i32)parent.h, hs);
        for (i32 i = (i32)0; i < (i32)siblings.count(); i = i + (i32)1)
            {
            UXRect s = ((RKRectBox* ?)siblings.get((u16)i)).r;
            RKGuides.linesOf((i32)s.x, (i32)s.w, vs);
            RKGuides.linesOf((i32)s.y, (i32)s.h, hs);
            }
        i32 right = (i32)r.x + (i32)r.w;
        i32 bottom = (i32)r.y + (i32)r.h;
        i32 hitX = (i32)-1;
        i32 hitY = (i32)-1;
        i32 nr = RKGuides.snapAxis(right, (i32)0, vs, (i32)RK_SNAP, &hitX);
        i32 nb = RKGuides.snapAxis(bottom, (i32)0, hs, (i32)RK_SNAP, &hitY);
        if (hitX >= (i32)0)
            {
            guides.add(RKGuide.make(hitX, true));
            }
        if (hitY >= (i32)0)
            {
            guides.add(RKGuide.make(hitY, false));
            }
        i32 nw = nr - (i32)r.x;
        // never inside-out
        if (nw < (i32)4)
            {
            nw = (i32)4;
            }
        i32 nh = nb - (i32)r.y;
        if (nh < (i32)4)
            {
            nh = (i32)4;
            }
        return UXGeom.make(r.x, r.y, (i16)nw, (i16)nh);
        }
    }
