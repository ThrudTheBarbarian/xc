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

#define RK_HANDLE 7 // corner handle, in pixels
#define RK_DASH 3   // the marquee frame's on/off run, in pixels

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

        // frame: a DASHED marquee, lit by short fills rather than drawLine (which loses verticals on
        // the backends whose drawLine is a triangle stand-in).  The breaks read as "this is a
        // selection", so a small control's edge is not mistaken for its own border.
        i16 dash = (i16)RK_DASH;
        for (i16 x = (i16)0; x < w; x = (i16)((i32)x + (i32)dash * (i32)2))
            {
            i16 run = (i16)((i32)x + (i32)dash <= (i32)w ? (i32)dash : (i32)w - (i32)x);
            g.fillRectRGB(UXGeom.make(x, (i16)0, run, (i16)1), (i32)38, (i32)38, (i32)38);
            g.fillRectRGB(UXGeom.make(x, (i16)(h - (i16)1), run, (i16)1), (i32)38, (i32)38, (i32)38);
            }
        for (i16 y = (i16)0; y < h; y = (i16)((i32)y + (i32)dash * (i32)2))
            {
            i16 run = (i16)((i32)y + (i32)dash <= (i32)h ? (i32)dash : (i32)h - (i32)y);
            g.fillRectRGB(UXGeom.make((i16)0, y, (i16)1, run), (i32)38, (i32)38, (i32)38);
            g.fillRectRGB(UXGeom.make((i16)(w - (i16)1), y, (i16)1, run), (i32)38, (i32)38, (i32)38);
            }

        i16 s = (i16)RK_HANDLE;
        self.handle(g, (i16)0, (i16)0);
        self.handle(g, (i16)(w - s), (i16)0);
        self.handle(g, (i16)0, (i16)(h - s));
        self.handle(g, (i16)(w - s), (i16)(h - s));
        }

    // A white square with a dark border, so it stands out on the form AND on the blue canvas.
    void handle(UXGraphics* g, i16 x, i16 y)
        {
        i16 s = (i16)RK_HANDLE;
        g.fillRectRGB(UXGeom.make(x, y, s, s), (i32)255, (i32)255, (i32)255);
        g.fillRectRGB(UXGeom.make(x, y, s, (i16)1), (i32)38, (i32)38, (i32)38);
        g.fillRectRGB(UXGeom.make(x, (i16)((i32)y + (i32)s - (i32)1), s, (i16)1), (i32)38, (i32)38, (i32)38);
        g.fillRectRGB(UXGeom.make(x, y, (i16)1, s), (i32)38, (i32)38, (i32)38);
        g.fillRectRGB(UXGeom.make((i16)((i32)x + (i32)s - (i32)1), y, (i16)1, s), (i32)38, (i32)38, (i32)38);
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
