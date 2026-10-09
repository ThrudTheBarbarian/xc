// RKAutoPreview.xc — the Size tab's moving preview: a box that grows and shrinks the way the
// selected control would under its autoresize checks, so the springs and struts can be seen
// without resizing the window.
//
// It loops while the designer is plausibly looking at it — the Size tab is showing and the mouse is
// over the preview or over the selected control on the canvas — which is Interface Builder's own
// rule.  The child's frame for a grown parent is computed with the toolkit's OWN solver
// (UXView.springPos / springSize), so the preview cannot drift from the layout the app will do.
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXViewDriver.xc" // UX_ANCHOR_*, UX_FLEX_* and the springs solver

#define RK_AUTO_STEPS 120 // the loop's length in ticks: one grow and one shrink
#define RK_AUTO_GROW 40   // how much the example parent grows, in pixels

class RKAutoPreview : UXView
    {
    i32 mask;  // the selected control's autoresize mask
    i32 phase; // 0..RK_AUTO_STEPS: where in the loop we are
    bool running;

    void init(void)
        {
        super.init();
        mask = (i32)(UX_ANCHOR_LEFT | UX_ANCHOR_TOP); // pinned, as a control with no checks
        phase = (i32)0;
        running = false;
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
    // Start / stop the loop.  Starting rewinds it, so a glance always begins with the base frame.
    void setRunning(bool on)
        {
        if (running == on)
            {
            return;
            }
        running = on;
        if (on)
            {
            phase = (i32)0;
            }
        self.setNeedsDisplay();
        }
    bool isRunning(void)
        {
        return running;
        }
    // One frame-clock step.
    void tick(void)
        {
        if (!running)
            {
            return;
            }
        phase = (phase + (i32)1) % (i32)RK_AUTO_STEPS;
        self.setNeedsDisplay();
        }
    // How far the example parent has grown this frame, 0..RK_AUTO_GROW and back.
    i32 grow(void)
        {
        i32 half = (i32)RK_AUTO_STEPS / (i32)2;
        i32 t = phase <= half ? phase : (i32)RK_AUTO_STEPS - phase;
        return t * (i32)RK_AUTO_GROW / half;
        }
    // The frame `c` takes in a parent that grew from (baseW, baseH) to (grownW, grownH), for `m`.
    // The same solve UXView.resizeSubviews uses, so the preview matches the real layout.
    static UXRect frameFor(i32 baseW, i32 baseH, UXRect c, i32 grownW, i32 grownH, i32 m)
        {
        bool hLead = (m & (i32)UX_ANCHOR_RIGHT) != (i32)0 && (m & (i32)UX_ANCHOR_LEFT) == (i32)0;
        bool hSize = (m & (i32)UX_FLEX_WIDTH) != (i32)0 ||
                     ((m & (i32)UX_ANCHOR_LEFT) != (i32)0 && (m & (i32)UX_ANCHOR_RIGHT) != (i32)0);
        bool vLead = (m & (i32)UX_ANCHOR_BOTTOM) != (i32)0 && (m & (i32)UX_ANCHOR_TOP) == (i32)0;
        bool vSize = (m & (i32)UX_FLEX_HEIGHT) != (i32)0 ||
                     ((m & (i32)UX_ANCHOR_TOP) != (i32)0 && (m & (i32)UX_ANCHOR_BOTTOM) != (i32)0);
        i32 nx = UXView.springPos((i32)c.x, (i32)c.w, baseW, grownW, hLead, hSize);
        i32 nw = UXView.springSize((i32)c.x, (i32)c.w, baseW, grownW, hLead, hSize);
        i32 ny = UXView.springPos((i32)c.y, (i32)c.h, baseH, grownH, vLead, vSize);
        i32 nh = UXView.springSize((i32)c.y, (i32)c.h, baseH, grownH, vLead, vSize);
        return UXGeom.make((i16)nx, (i16)ny, (i16)nw, (i16)nh);
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        i16 m = (i16)12; // a margin, so the growth has room
        i32 baseW = (i32)b.w - (i32)m * (i32)2;
        i32 baseH = (i32)b.h - (i32)m * (i32)2;
        if (baseW < (i32)20 || baseH < (i32)20)
            {
            return;
            }
        i32 gp = self.grow();
        i32 gw = baseW + gp;
        i32 gh = baseH + gp;
        // the example parent: its base outline, and the grown box over it
        g.fillRectRGB(UXGeom.make(m, m, (i16)baseW, (i16)baseH), (i32)238, (i32)241, (i32)247);
        g.fillRectRGB(UXGeom.make(m, m, (i16)gw, (i16)1), (i32)120, (i32)132, (i32)156);
        g.fillRectRGB(UXGeom.make(m, (i16)((i32)m + gh - (i32)1), (i16)gw, (i16)1), (i32)120, (i32)132, (i32)156);
        g.fillRectRGB(UXGeom.make(m, m, (i16)1, (i16)gh), (i32)120, (i32)132, (i32)156);
        g.fillRectRGB(UXGeom.make((i16)((i32)m + gw - (i32)1), m, (i16)1, (i16)gh), (i32)120, (i32)132, (i32)156);
        // the control: a fixed fraction of the base parent, moved per the mask
        UXRect c = UXGeom.make((i16)8, (i16)8, (i16)(baseW / (i32)2), (i16)(baseH / (i32)2));
        UXRect f = RKAutoPreview.frameFor(baseW, baseH, c, gw, gh, mask);
        g.fillRectRGB(UXGeom.make((i16)((i32)m + (i32)f.x), (i16)((i32)m + (i32)f.y), f.w, f.h),
                      (i32)90, (i32)130, (i32)220);
        }

    // The loop runs only while the mouse is over the preview; the canvas is the controller's job.
    void mouseMoved(UXEvent* e)
        {
        self.setRunning(true);
        }
    void mouseExited(UXEvent* e)
        {
        self.setRunning(false);
        }
    }
