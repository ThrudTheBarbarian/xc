// test_gtk_input.xc — hover, the secondary button and the wheel on GTK.
//
// Pointer events go through the shim's own decision (ux_gtk_input -- what a real GdkEvent is turned
// into) and the toolkit's dispatch, into a view that records what reached it: a move with no button
// down is a HOVER, the secondary button is the context menu and starts no drag, and the wheel carries
// the DOM's deltaY in pixels (positive down) with its notches the other way round.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

extern void ux_gtk_input(i32 handle, i32 what, i32 button, double x, double y, i32 px);

class Pad : UXView
    {
    i32 moved;
    i32 downs;
    i32 right;
    i32 wheels;
    i32 wheelPx;
    i32 wheelNotches;
    void mouseMoved(UXEvent* e) { moved = moved + (i32)1; }
    void mouseDown(UXEvent* e) { downs = downs + (i32)1; }
    void rightMouseDown(UXEvent* e) { right = right + (i32)1; }
    void scrollWheel(UXEvent* e) { wheels = wheels + (i32)1; wheelPx = e.b; wheelNotches = e.a; }
    }

i32 gFails = 0;
void ck(bool ok, u8* what)
    {
    if (ok) { Stdio.printf("  ok   %s\n", what); }
    else { Stdio.printf("  FAIL %s\n", what); gFails = gFails + (i32)1; }
    }

void main(void)
    {
    UXGtkDriver* d = new UXGtkDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display for gtk_init\n");
        return;
        }
    UXApplication* app = new UXApplication();
    gApp = app; // what run() sets; this test dispatches without running the loop
    Pad* pad = new Pad();
    UXWindow* win = new UXWindow();
    win.open((u8*)"Input", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)120), pad);
    app.addWindow(win);
    win.displayAll();
    i32 h = win.handle;

    ux_gtk_input(h, (i32)3, (i32)0, 50.0, 40.0, (i32)0);   // a move, no button down
    ck(pad.moved == (i32)1, "a move with no button down is a HOVER (mouseMoved)");
    ux_gtk_input(h, (i32)1, (i32)3, 50.0, 40.0, (i32)0);   // the secondary button
    ck(pad.right == (i32)1 && pad.downs == (i32)0, "the secondary button is rightMouseDown, not a press");
    ux_gtk_input(h, (i32)3, (i32)0, 60.0, 40.0, (i32)0);
    ck(pad.moved == (i32)2, "...and starts no drag: the next move is still a hover");
    ux_gtk_input(h, (i32)2, (i32)3, 60.0, 40.0, (i32)0);
    ux_gtk_input(h, (i32)4, (i32)0, 50.0, 40.0, (i32)-100); // one wheel click up
    ck(pad.wheels == (i32)1 && pad.wheelPx == (i32)-100, "the wheel carries the DOM's deltaY in pixels");
    ck(pad.wheelNotches == (i32)1, "...and its notches the other way round (one notch UP)");
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: GTK input -- hover, the secondary button and the wheel decode and route\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
