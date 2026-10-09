// RKAutoSizing.xc — the Autosizing widget from Interface Builder: a square for the superview, the
// view's rectangle inside it, and between them a STRUT (a FIXED margin) or a SPRING (a flexible
// one) on each side, with a strut or spring across the rectangle for its width and its height.  A
// click on one toggles it.  The six bits are the same UX_ANCHOR_* / UX_FLEX_* mask the loader gives
// the view, so the widget and the layout are one thing and cannot disagree.
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXViewDriver.xc" // UX_ANCHOR_*, UX_FLEX_*

class RKAutoSizing : UXView
    {
    i32 mask;
    callback changed void(i32 m);

    void init(void)
        {
        super.init();
        mask = (i32)(UX_ANCHOR_LEFT | UX_ANCHOR_TOP | UX_FLEX_WIDTH | UX_FLEX_HEIGHT);
        changed = (callback void(i32 m))0;
        }
    void setMask(i32 m)
        {
        mask = m;
        self.setNeedsDisplay();
        }
    i32 maskOf(void)
        {
        return mask;
        }
    // Toggle one bit — what a click on its strut or spring does.
    void toggle(i32 bit)
        {
        mask = mask ^ bit;
        self.setNeedsDisplay();
        if (changed)
            {
            changed(mask);
            }
        }

    // The superview square, and the view rectangle a third in from each side.
    static void boxes(UXRect b, UXRect* outer, UXRect* inner)
        {
        i16 m = (i16)8;
        outer[0] = UXGeom.make(m, m, (i16)((i32)b.w - (i32)m * (i32)2), (i16)((i32)b.h - (i32)m * (i32)2));
        i16 w3 = (i16)((i32)outer[0].w / (i32)3);
        i16 h3 = (i16)((i32)outer[0].h / (i32)3);
        inner[0] = UXGeom.make((i16)((i32)outer[0].x + (i32)w3), (i16)((i32)outer[0].y + (i32)h3), w3, h3);
        }
    // Which bit a point toggles, or 0.
    i32 bitAt(i16 lx, i16 ly)
        {
        UXRect outer;
        UXRect inner;
        RKAutoSizing.boxes(self.bounds(), &outer, &inner);
        i16 ix1 = (i16)((i32)inner.x + (i32)inner.w);
        i16 iy1 = (i16)((i32)inner.y + (i32)inner.h);
        i16 ox1 = (i16)((i32)outer.x + (i32)outer.w);
        i16 oy1 = (i16)((i32)outer.y + (i32)outer.h);
        if (ly >= inner.y && ly < iy1)
            {
            if (lx >= outer.x && lx < inner.x) { return (i32)UX_ANCHOR_LEFT; }
            if (lx >= ix1 && lx < ox1) { return (i32)UX_ANCHOR_RIGHT; }
            }
        if (lx >= inner.x && lx < ix1)
            {
            if (ly >= outer.y && ly < inner.y) { return (i32)UX_ANCHOR_TOP; }
            if (ly >= iy1 && ly < oy1) { return (i32)UX_ANCHOR_BOTTOM; }
            }
        i16 wy0 = (i16)((i32)inner.y + (i32)inner.h / (i32)3);
        i16 wy1 = (i16)((i32)inner.y + (i32)inner.h * (i32)2 / (i32)3);
        i16 wx0 = (i16)((i32)inner.x + (i32)inner.w / (i32)3);
        i16 wx1 = (i16)((i32)inner.x + (i32)inner.w * (i32)2 / (i32)3);
        if (lx >= inner.x && lx < ix1 && ly >= wy0 && ly < wy1) { return (i32)UX_FLEX_WIDTH; }
        if (lx >= wx0 && lx < wx1 && ly >= inner.y && ly < iy1) { return (i32)UX_FLEX_HEIGHT; }
        return (i32)0;
        }
    void mouseDown(UXEvent* e)
        {
        UXRect a = self.absoluteFrame();
        i32 bit = self.bitAt((i16)((i32)e.x - (i32)a.x), (i16)((i32)e.y - (i32)a.y));
        if (bit != 0)
            {
            self.toggle(bit);
            }
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect outer;
        UXRect inner;
        RKAutoSizing.boxes(self.bounds(), &outer, &inner);
        RKAutoSizing.frame4(g, outer, (i32)150, (i32)158, (i32)178); // the superview
        g.fillRectRGB(inner, (i32)214, (i32)226, (i32)246);           // the view
        RKAutoSizing.frame4(g, inner, (i32)90, (i32)130, (i32)220);
        i16 my = (i16)((i32)inner.y + (i32)inner.h / (i32)2); // the margins' lines
        i16 mx = (i16)((i32)inner.x + (i32)inner.w / (i32)2);
        i16 ix1 = (i16)((i32)inner.x + (i32)inner.w);
        i16 iy1 = (i16)((i32)inner.y + (i32)inner.h);
        i16 ox1 = (i16)((i32)outer.x + (i32)outer.w);
        i16 oy1 = (i16)((i32)outer.y + (i32)outer.h);
        RKAutoSizing.bar(g, outer.x, my, inner.x, my, (mask & (i32)UX_ANCHOR_LEFT) != 0);
        RKAutoSizing.bar(g, ix1, my, ox1, my, (mask & (i32)UX_ANCHOR_RIGHT) != 0);
        RKAutoSizing.bar(g, mx, outer.y, mx, inner.y, (mask & (i32)UX_ANCHOR_TOP) != 0);
        RKAutoSizing.bar(g, mx, iy1, mx, oy1, (mask & (i32)UX_ANCHOR_BOTTOM) != 0);
        RKAutoSizing.bar(g, inner.x, my, ix1, my, (mask & (i32)UX_FLEX_WIDTH) == 0);
        RKAutoSizing.bar(g, mx, inner.y, mx, iy1, (mask & (i32)UX_FLEX_HEIGHT) == 0);
        }
    // A strut is a solid line; a spring is the same line with a box in its middle.
    static void bar(UXGraphics* g, i16 x0, i16 y0, i16 x1, i16 y1, bool strut)
        {
        bool horiz = y0 == y1;
        if (horiz)
            {
            g.fillRectRGB(UXGeom.make(x0, (i16)(y0 - (i16)1), (i16)((i32)x1 - (i32)x0), (i16)3), (i32)120, (i32)132, (i32)156);
            if (!strut)
                {
                g.fillRectRGB(UXGeom.make((i16)(((i32)x0 + (i32)x1) / (i32)2 - (i32)2), (i16)(y0 - (i32)4), (i16)5, (i16)7), (i32)120, (i32)132, (i32)156);
                }
            }
        else
            {
            g.fillRectRGB(UXGeom.make((i16)(x0 - (i16)1), y0, (i16)3, (i16)((i32)y1 - (i32)y0)), (i32)120, (i32)132, (i32)156);
            if (!strut)
                {
                g.fillRectRGB(UXGeom.make((i16)(x0 - (i32)4), (i16)(((i32)y0 + (i32)y1) / (i32)2 - (i32)2), (i16)7, (i16)5), (i32)120, (i32)132, (i32)156);
                }
            }
        }
    static void frame4(UXGraphics* g, UXRect r, i32 rr, i32 gg, i32 bb)
        {
        g.fillRectRGB(UXGeom.make(r.x, r.y, r.w, (i16)1), rr, gg, bb);
        g.fillRectRGB(UXGeom.make(r.x, (i16)((i32)r.y + (i32)r.h - (i32)1), r.w, (i16)1), rr, gg, bb);
        g.fillRectRGB(UXGeom.make(r.x, r.y, (i16)1, r.h), rr, gg, bb);
        g.fillRectRGB(UXGeom.make((i16)((i32)r.x + (i32)r.w - (i32)1), r.y, (i16)1, r.h), rr, gg, bb);
        }
    }
