// RKDock.xc — the strip above the canvas holding the form's non-view objects, as Interface
// Builder's scene dock does: File's Owner, First Responder and the document's objects.
//
// They are not on the canvas, but connections go to and from them, so they need somewhere a line
// can be drawn to.  A click selects one, as its outline row does; a control-drag (the secondary
// button) starts a connection from it.
#import "Array.xc"
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"
#import "UXRscModel.xc"
#import "RKOutline.xc"
#import "RKWiring.xc"

class RKDockItem : Object
    {
    RKEnd* end;
    u8* label;
    UXRect r; // in the dock's coordinates
    }

class RKDock : UXView
    {
    Array<RKDockItem>* items;
    RKEnd* highlighted; // the drop target under a line being drawn, or 0
    callback picked void(RKEnd* e);               // a click on an item
    callback wireFrom void(RKEnd* e, i32 wx, i32 wy); // a control-drag starting on an item, at a window point

    void init(void)
        {
        super.init();
        items = new Array();
        highlighted = (RKEnd*)0;
        picked = (callback void(RKEnd * e))0;
        wireFrom = (callback void(RKEnd * e, i32 wx, i32 wy))0;
        }

    // List the document's placeholders and objects, left to right.
    void rebuild(UXRscDoc* d)
        {
        items = new Array();
        i16 x = (i16)6;
        x = self.add(RKEnd.placeholder((i32)RKON_OWNER, (i32)0), (u8*)"File's Owner", x);
        x = self.add(RKEnd.placeholder((i32)RKON_FIRSTR, (i32)0), (u8*)"First Responder", x);
        if (d != (UXRscDoc*)0)
            {
            for (u32 i = (u32)0; i < d.topObjects.count(); i = i + (u32)1)
                {
                UXRscTopObject* to = (UXRscTopObject* ?)d.topObjects.get(i);
                x = self.add(RKEnd.placeholder((i32)RKON_OBJECT, to.id), RKOutline.topLabel(to), x);
                }
            }
        self.setNeedsDisplay();
        }
    i16 add(RKEnd* e, u8* label, i16 x)
        {
        RKDockItem* it = new RKDockItem();
        it.end = e;
        it.label = label;
        i32 w = (i32)UXRscTree.len(label) * (i32)7 + (i32)20;
        it.r = UXGeom.make(x, (i16)4, (i16)w, (i16)20);
        items.add(it);
        return (i16)((i32)x + w + (i32)6);
        }

    // The item at a point in the dock, or 0.
    RKDockItem* itemAt(i32 lx, i32 ly)
        {
        for (u32 i = (u32)0; i < items.count(); i = i + (u32)1)
            {
            RKDockItem* it = (RKDockItem* ?)items.get(i);
            if (lx >= (i32)it.r.x && lx < (i32)it.r.x + (i32)it.r.w && ly >= (i32)it.r.y && ly < (i32)it.r.y + (i32)it.r.h)
                {
                return it;
                }
            }
        return (RKDockItem*)0;
        }
    // The item at a window point, or 0: where a line drawn from the canvas ended.
    RKEnd* endAtWindow(i32 wx, i32 wy)
        {
        UXRect a = self.absoluteFrame();
        RKDockItem* it = self.itemAt(wx - (i32)a.x, wy - (i32)a.y);
        return it != (RKDockItem*)0 ? it.end : (RKEnd*)0;
        }
    // An item's centre, in window coordinates: where a line to or from it attaches.
    void centreOf(RKEnd* e, i32* wx, i32* wy)
        {
        UXRect a = self.absoluteFrame();
        for (u32 i = (u32)0; i < items.count(); i = i + (u32)1)
            {
            RKDockItem* it = (RKDockItem* ?)items.get(i);
            if (it.end == e || (it.end.kind == e.kind && it.end.topId == e.topId))
                {
                wx[0] = (i32)a.x + (i32)it.r.x + (i32)it.r.w / (i32)2;
                wy[0] = (i32)a.y + (i32)it.r.y + (i32)it.r.h / (i32)2;
                return;
                }
            }
        wx[0] = (i32)a.x;
        wy[0] = (i32)a.y;
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRectRGB(UXGeom.make((i16)0, (i16)0, b.w, b.h), (i32)236, (i32)236, (i32)236);
        g.fillRectRGB(UXGeom.make((i16)0, (i16)((i32)b.h - (i32)1), b.w, (i16)1), (i32)200, (i32)200, (i32)200);
        for (u32 i = (u32)0; i < items.count(); i = i + (u32)1)
            {
            RKDockItem* it = (RKDockItem* ?)items.get(i);
            bool hot = highlighted != (RKEnd*)0 && highlighted.kind == it.end.kind && highlighted.topId == it.end.topId;
            if (hot)
                {
                g.fillRectRGB(it.r, (i32)30, (i32)120, (i32)255);
                }
            else
                {
                g.fillRectRGB(it.r, (i32)250, (i32)250, (i32)250);
                }
            RKDock.frame(g, it.r);
            g.drawTextRGBA(it.label, (i16)((i32)it.r.x + (i32)10), (i16)((i32)it.r.y + (i32)3),
                           hot ? (i32)255 : (i32)40, hot ? (i32)255 : (i32)40, hot ? (i32)255 : (i32)40, (i32)255, (i32)12);
            }
        }
    static void frame(UXGraphics* g, UXRect r)
        {
        g.fillRectRGB(UXGeom.make(r.x, r.y, r.w, (i16)1), (i32)170, (i32)170, (i32)170);
        g.fillRectRGB(UXGeom.make(r.x, (i16)((i32)r.y + (i32)r.h - (i32)1), r.w, (i16)1), (i32)170, (i32)170, (i32)170);
        g.fillRectRGB(UXGeom.make(r.x, r.y, (i16)1, r.h), (i32)170, (i32)170, (i32)170);
        g.fillRectRGB(UXGeom.make((i16)((i32)r.x + (i32)r.w - (i32)1), r.y, (i16)1, r.h), (i32)170, (i32)170, (i32)170);
        }

    void mouseDown(UXEvent* e)
        {
        UXRect a = self.absoluteFrame();
        RKDockItem* it = self.itemAt((i32)e.x - (i32)a.x, (i32)e.y - (i32)a.y);
        if (it != (RKDockItem*)0 && picked)
            {
            picked(it.end);
            }
        }
    void rightMouseDown(UXEvent* e)
        {
        UXRect a = self.absoluteFrame();
        RKDockItem* it = self.itemAt((i32)e.x - (i32)a.x, (i32)e.y - (i32)a.y);
        if (it != (RKDockItem*)0 && wireFrom)
            {
            wireFrom(it.end, (i32)e.x, (i32)e.y);
            }
        }
    }
