// RKSelection.xc — the selection frame drawn over the selected widget.
//
// A separate view rather than something the widgets draw themselves, and that
// is the important part: the canvas holds REAL UXKit widgets, and a real
// widget has no idea it is being edited.  Teaching UXButton to draw an editor
// selection would put editor concerns inside the toolkit and undo the reason
// the canvas hosts live widgets at all.
//
// So selection is an overlay: a sibling view positioned over the selected
// widget's rectangle, drawing a frame and corner handles.  It is not a hit
// target — it sits above the widget only visually — so clicks still reach the
// thing underneath.
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

#define RK_HANDLE 5 // corner handle, in pixels

class RKSelectionFrame : UXView
    {
    // Where a press on the frame goes.  The frame is drawn on top of the edit
    // overlay so its handles are visible, which also makes it the thing a
    // press on a handle lands on -- so it hands the event straight back rather
    // than growing a second, divergent copy of the drag logic.  A callback
    // rather than a pointer to the overlay: this file stays art, and knows
    // nothing about dragging.
    callback press void(UXEvent* e);

    void init(void)
        {
        super.init();
        press = (callback void(UXEvent * e))0;
        }

    // A hairline frame plus four corner handles — the classic direct-
    // manipulation affordance, and the handles are where resize will attach
    // when dragging lands.
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        i16 w = b.w;
        i16 h = b.h;
        if (w <= (i16)0 || h <= (i16)0)
            {
            return;
            }

        // frame: four 1px fills rather than drawLine, which loses verticals on
        // the backends whose drawLine is a triangle stand-in (the same reason
        // UXSplitView draws its divider this way).
        g.fillRect(UXGeom.make((i16)0, (i16)0, w, (i16)1), (i32)1);
        g.fillRect(UXGeom.make((i16)0, (i16)(h - (i16)1), w, (i16)1), (i32)1);
        g.fillRect(UXGeom.make((i16)0, (i16)0, (i16)1, h), (i32)1);
        g.fillRect(UXGeom.make((i16)(w - (i16)1), (i16)0, (i16)1, h), (i32)1);

        i16 s = (i16)RK_HANDLE;
        self.handle(g, (i16)0, (i16)0);
        self.handle(g, (i16)(w - s), (i16)0);
        self.handle(g, (i16)0, (i16)(h - s));
        self.handle(g, (i16)(w - s), (i16)(h - s));
        }

    void handle(UXGraphics* g, i16 x, i16 y)
        {
        i16 s = (i16)RK_HANDLE;
        g.fillRect(UXGeom.make(x, y, s, s), (i32)1);
        }

    // It must never take the keyboard -- that belongs to whatever the
    // inspector is editing -- but it does pass the press on.
    bool acceptsFirstResponder(void)
        {
        return false;
        }
    void mouseDown(UXEvent* e)
        {
        if (press)
            {
            press(e);
            }
        }
    }
