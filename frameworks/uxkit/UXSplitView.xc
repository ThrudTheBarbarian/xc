// UXSplitView.xc — two resizable panes with a draggable divider between them (an NSSplitView shape).
//
// Neutral: the panes are plain container views a client fills, the divider is a thin view, and dragging
// it re-lays the two panes.  The drag is the driver's modal trackDragStep (the same primitive the table
// uses for drag-select), so it works on every backend that implements it.  Content in a pane — including
// native controls — reflows on the next paint because a resize re-runs realizeTree with the new frames.
//
// Layout: pane0 is the FIXED side (its extent is the divider position); pane1 FLEXES to fill the rest,
// so a split view resizing (a window growing) grows the detail pane and leaves the sidebar put.
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXApplication.xc" // gApp — repaint mid divider-drag (the run loop is parked in trackDragStep)

#define UX_SPLIT_DIVIDER 10 // divider thickness (also the grab target — 6 was too thin to hit)
#define UX_SPLIT_MIN 40     // smallest a pane may be dragged to

// The divider: a grey bar with a centred grip line; a press starts the drag.
class UXSplitDivider : UXView
    {
    weak : UXSplitView* split;
    void init(void)
        {
        super.init();
        split = (UXSplitView*)0;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        // Just a hairline at the centre (the seam); the wide bounds are the grab zone, not a bar — the
        // panes drew underneath us, so no fill.  pen 9 = the subtle separator grey.
        // 1px FILLS, not drawLine: the line stand-in on several graphics
        // loses verticals entirely, and the seam vanished from the portraits
        if (split != (UXSplitView*)0 && split.isVertical())
            {
            g.fillRect(UXGeom.make((i16)0, (i16)(b.h / (i16)2), b.w, (i16)1), (i32)9);
            }
        else
            {
            g.fillRect(UXGeom.make((i16)(b.w / (i16)2), (i16)0, (i16)1, b.h), (i32)9);
            }
        }
    void mouseDown(UXEvent* e)
        {
        if (split != (UXSplitView*)0)
            {
            split.beginDragDivider();
            }
        }
    }

    class UXSplitView : UXView
    {
    UXView* pane0; // the fixed side (its extent = dividerPos)
    UXView* pane1; // the flexible side (fills the rest)
    UXSplitDivider* divider;
    bool vertical;  // false: side by side (vertical divider); true: stacked (horizontal divider)
    i16 dividerPos; // x (horizontal) or y (vertical) of the divider's near edge

    void init(void)
        {
        super.init();
        pane0 = (UXView*)0;
        pane1 = (UXView*)0;
        divider = (UXSplitDivider*)0;
        vertical = false;
        dividerPos = (i16)120;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }
    bool isVertical(void)
        {
        return vertical;
        }
    // Set BEFORE the split view is added to a tree (it decides the initial layout).
    void setVertical(bool v)
        {
        vertical = v;
        }
    void setDividerPos(i16 p)
        {
        dividerPos = p;
        self.layoutPanes();
        self.setNeedsDisplay();
        }
    i16 dividerPosition(void)
        {
        return dividerPos;
        }

    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        pane0 = new UXView();
        self.addSubview(pane0, UXGeom.make((i16)0, (i16)0, (i16)1, (i16)1));
        pane1 = new UXView();
        self.addSubview(pane1, UXGeom.make((i16)0, (i16)0, (i16)1, (i16)1));
        divider = new UXSplitDivider();
        divider.split = self;
        self.addSubview(divider, UXGeom.make((i16)0, (i16)0, (i16)1, (i16)1));
        self.layoutPanes();
        }

    // clients add content into these
    UXView* firstPane(void)
        {
        return pane0;
        }
    UXView* secondPane(void)
        {
        return pane1;
        }

    // Place the two panes + the divider for the current frame + divider position.
    // The panes ABUT at dividerPos (Cocoa look: a hairline, not a fat bar); the divider is a wide
    // GRAB band centred on the seam, drawn last (on top) so it wins the hit test but only paints a
    // 1px line — the panes show through the rest of the band.
    void layoutPanes(void)
        {
        if (pane0 == (UXView*)0)
            {
            return;
            }
        UXRect f = self.frame();
        i16 half = (i16)(UX_SPLIT_DIVIDER / (i16)2);
        // Capture the panes' OLD sizes so we can cascade the springs to THEIR content after re-sizing:
        // this method sets the pane frames directly (it is not the window-resize path), so nothing else
        // flexes the client's content to fill the pane.  Without this the content keeps its old size while
        // the pane grows under the divider drag, leaving a transparent strip — invisible on backends that
        // erase the damage rect (AppKit/Win32) but a smear of old divider hairlines on GEM, which doesn't.
        UXRect p0o = pane0.frame();
        UXRect p1o = pane1.frame();
        UXRect p0n;
        UXRect p1n;
        if (!vertical)
            {
            p0n = UXGeom.make((i16)0, (i16)0, dividerPos, f.h);
            p1n = UXGeom.make(dividerPos, (i16)0, (i16)((i32)f.w - (i32)dividerPos), f.h);
            owner.setFrameOf(pane0.index, p0n);
            owner.setFrameOf(pane1.index, p1n);
            owner.setFrameOf(divider.index, UXGeom.make((i16)(dividerPos - half), (i16)0, (i16)UX_SPLIT_DIVIDER, f.h));
            }
        else
            {
            p0n = UXGeom.make((i16)0, (i16)0, f.w, dividerPos);
            p1n = UXGeom.make((i16)0, dividerPos, f.w, (i16)((i32)f.h - (i32)dividerPos));
            owner.setFrameOf(pane0.index, p0n);
            owner.setFrameOf(pane1.index, p1n);
            owner.setFrameOf(divider.index, UXGeom.make((i16)0, (i16)(dividerPos - half), f.w, (i16)UX_SPLIT_DIVIDER));
            }
        pane0.resizeSubviews((i32)p0o.w, (i32)p0o.h, (i32)p0n.w, (i32)p0n.h); // flex the client's content
        pane1.resizeSubviews((i32)p1o.w, (i32)p1o.h, (i32)p1n.w, (i32)p1n.h); // to fill the resized pane
        }

    // Reflow the panes when the split view itself resizes (window grew): pane0 keeps its extent, pane1
    // flexes.  The neutral springs & struts call this via resizeSubviews; we clamp + re-lay.
    void resizeSubviews(i32 oldW, i32 oldH, i32 newW, i32 newH)
        {
        i16 mx = (i16)((!vertical ? newW : newH) - (i32)UX_SPLIT_MIN); // panes abut — no divider width to subtract
        if (dividerPos > mx)
            {
            dividerPos = mx;
            }
        self.layoutPanes();
        }

    // Drag the divider: follow the pointer (modal via trackDragStep), clamp to leave both panes usable,
    // re-lay, and repaint live.  Native controls in the panes reposition on the repaint (realizeTree).
    void beginDragDivider(void)
        {
        UXRect a = self.absoluteFrame();
        i32 base = !vertical ? (i32)a.x : (i32)a.y;
        i32 span = !vertical ? (i32)self.frame().w : (i32)self.frame().h;
        i32 x = (i32)0;
        i32 y = (i32)0;
        while (gDriver.trackDragStep(&x, &y) != (i32)0)
            {
            i32 p = (!vertical ? x : y) - base;
            if (p < (i32)UX_SPLIT_MIN)
                {
                p = (i32)UX_SPLIT_MIN;
                }
            i32 mx = span - (i32)UX_SPLIT_MIN; // panes abut — no divider width to subtract
            if (p > mx)
                {
                p = mx;
                }
            self.setDividerPos((i16)p);
            if (gApp != (UXApplication*)0)
                {
                gApp.displayIfNeeded();
                }
            }
        }
    }
