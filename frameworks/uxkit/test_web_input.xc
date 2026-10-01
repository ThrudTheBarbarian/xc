// test_web_input.xc — hover, the secondary button and the wheel on the web backend.
//
// Ring slots in the loader's own shape go through the driver's real decoder (decodeRing) and the
// toolkit's real dispatch, into a view that records what reached it: a move with no button down is a
// HOVER (mouseMoved), the same move with the primary button down is a DRAG, the secondary button is
// the context menu (rightMouseDown) and never starts a drag, and the wheel carries the DOM's deltaY
// in pixels.  The page's half -- the loader pushing these slots -- is the compiler's runtime.
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

class Pad : UXView
    {
    i32 moved;
    i32 dragged;
    i32 right;
    i32 wheels;
    i32 wheelPx;
    void mouseMoved(UXEvent* e) { moved = moved + (i32)1; }
    void mouseDragged(UXEvent* e) { dragged = dragged + (i32)1; }
    void rightMouseDown(UXEvent* e) { right = right + (i32)1; }
    void scrollWheel(UXEvent* e) { wheels = wheels + (i32)1; wheelPx = e.b; }
    }

i32 gFails = 0;
void ck(bool ok, u8* what)
    {
    if (ok) { Stdio.printf("  ok   %s\n", what); }
    else { Stdio.printf("  FAIL %s\n", what); gFails = gFails + (i32)1; }
    }

UXWebDriver@ gWd;
UXApplication@ gApp;
UXEvent@ gEv;
// Feed one slot through the decoder and the dispatch, as nextEvent + the run loop would.
UXEvent* slot(i32 t, i32 a, i32 b, i32 c)
    {
    i32 r[8];
    r[0] = t; r[1] = a; r[2] = b; r[3] = c;
    r[4] = (i32)0; r[5] = (i32)0; r[6] = (i32)0; r[7] = (i32)0;
    gEv.init();
    gWd.decodeRing(&r[(i32)0], gEv);
    gApp.dispatchEvent(gEv);
    return gEv;
    }

void main(void)
    {
    gWd = new UXWebDriver();
    gDriver = gWd;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        return;
        }
    gApp = new UXApplication();
    gEv = new UXEvent();
    Pad* pad = new Pad();
    UXWindow* win = new UXWindow();
    win.open((u8*)"Input", UXGeom.make((i16)0, (i16)0, (i16)200, (i16)120), pad);
    gApp.addWindow(win);
    win.displayAll();

    UXEvent* e = slot((i32)3, (i32)50, (i32)40, (i32)0);
    ck(e.kind == (u8)UXEventMouseMoved, "a move with no button down decodes as a HOVER");
    ck(pad.moved == (i32)1 && pad.dragged == (i32)0, "...and reaches the view's mouseMoved");

    slot((i32)1, (i32)50, (i32)40, (i32)0);  // primary down
    e = slot((i32)3, (i32)60, (i32)40, (i32)0);
    ck(e.kind == (u8)UXEventMouseDragged, "the same move with the primary button down is a DRAG");
    slot((i32)2, (i32)60, (i32)40, (i32)0);  // primary up
    e = slot((i32)3, (i32)70, (i32)40, (i32)0);
    ck(e.kind == (u8)UXEventMouseMoved, "...and a hover again once it is released");

    e = slot((i32)1, (i32)50, (i32)40, (i32)2); // secondary down
    ck(e.kind == (u8)UXEventRightMouseDown, "the secondary button decodes as rightMouseDown");
    ck(pad.right == (i32)1, "...and reaches the view");
    e = slot((i32)3, (i32)55, (i32)40, (i32)0);
    ck(e.kind == (u8)UXEventMouseMoved, "...and does not start a drag");

    e = slot((i32)8, (i32)50, (i32)40, (i32)-120);
    ck(e.kind == (u8)UXEventWheel && e.b == (i32)-120, "the wheel carries the DOM's deltaY in pixels");
    ck(pad.wheels == (i32)1 && pad.wheelPx == (i32)-120, "...and reaches the view's scrollWheel");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: web input -- hover, drag, the secondary button and the wheel decode and route\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
