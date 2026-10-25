// test_trackmouse.xc — UXView.trackMouse follows a press to its release on the desktop: called from
// mouseDown, it hands the view's mouseDragged each move and its mouseUp the release, so a view drags
// the same way here as on the touch backends, with no driver in sight.  A press, two moves and a
// release are fed through the backend's real event path (headless).  A press the program makes up
// itself (mouseDown called directly) returns at once.
//
//   -A arm64 (AppKit, headless) or -A arm64 -D UX_TRACK_GTK (GTK).  Build+run: sh run_trackmouse.sh
#import <Stdio.xc>
#if UX_TRACK_GTK
#import "UXGtkDriver.xc"
extern void ux_gtk_post_press(i32 handle, i32 x, i32 y);
extern void ux_gtk_post_motion(i32 x, i32 y);
extern void ux_gtk_post_release(void);
#else
#import "UXAppKitDriver.xc"
extern void ux_ak_post_mouse(i32 handle, i32 kind, i32 x, i32 y);
#endif
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"

i32 gWin;
i32 gDowns;
i32 gDrags;
i32 gUps;
i32 gLastX;
i32 gLastY;
i32 gOrderOK;
bool gMadeUp;  // the press below that the test makes up itself
bool gMadeUpReturned;

// The next step of the drag, fed while it is followed (GTK steps wait for a move that is not there yet).
void feed(i32 step)
    {
#if UX_TRACK_GTK
    if (step == (i32)1)
        {
        ux_gtk_post_motion((i32)55, (i32)44);
        }
    else if (step == (i32)2)
        {
        ux_gtk_post_motion((i32)70, (i32)61);
        }
    else
        {
        ux_gtk_post_release();
        }
#endif
    }

class Dragger : UXView
    {
    void mouseDown(UXEvent* e)
        {
        if (gMadeUp)
            {
            self.trackMouse(e); // no platform press behind it: must return at once
            gMadeUpReturned = true;
            return;
            }
        gDowns = gDowns + (i32)1;
#if UX_TRACK_GTK
        feed((i32)1);
#else
        ux_ak_post_mouse(gWin, (i32)3, (i32)55, (i32)44);
        ux_ak_post_mouse(gWin, (i32)3, (i32)70, (i32)61);
        ux_ak_post_mouse(gWin, (i32)2, (i32)70, (i32)61);
#endif
        self.trackMouse(e);
        Stdio.printf("  trackMouse returned: %d moves, %d release\n", gDrags, gUps);
        }
    void mouseDragged(UXEvent* e)
        {
        gDrags = gDrags + (i32)1;
        if (gUps == (i32)0 && ((gDrags == (i32)1 && (i32)e.x == (i32)55 && (i32)e.y == (i32)44) ||
                               (gDrags == (i32)2 && (i32)e.x == (i32)70 && (i32)e.y == (i32)61)))
            {
            gOrderOK = gOrderOK + (i32)1;
            }
        feed(gDrags + (i32)1);
        }
    void mouseUp(UXEvent* e)
        {
        gUps = gUps + (i32)1;
        gLastX = (i32)e.x;
        gLastY = (i32)e.y;
        }
    }

void main(void)
    {
#if UX_TRACK_GTK
    UXGtkDriver* d = new UXGtkDriver();
    gDriver = d;
#else
    UXAppKitDriver* d = new UXAppKitDriver();
    d.setHeadless(true);
    gDriver = d;
#endif
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display\n");
        return;
        }
    UXApplication* app = new UXApplication();
    app.setDriver((UXViewDriver*)d);
    gApp = app;
    UXWindow* win = new UXWindow();
    Dragger* v = new Dragger();
    app.addWindow(win);
    win.open((u8*)"Drag", UXGeom.make((i16)60, (i16)60, (i16)200, (i16)150), v);
    win.tree.finalise();
    win.displayAll();
    gWin = win.handle;
#if UX_TRACK_GTK
    ux_gtk_post_press(win.handle, (i32)40, (i32)30);
#else
    ux_ak_post_mouse(win.handle, (i32)1, (i32)40, (i32)30);
    UXEvent* ev = new UXEvent();
    for (i32 i = (i32)0; i < (i32)20 && gDowns == (i32)0; i = i + (i32)1)
        {
        gDriver.nextEvent((i32)10, ev);
        app.dispatchEvent(ev);
        }
#endif
    i32 fails = (i32)0;
    if (gDowns != (i32)1)
        {
        Stdio.printf("  FAIL the press reached the view (%d)\n", gDowns);
        fails = fails + (i32)1;
        }
    if (gDrags != (i32)2 || gOrderOK != (i32)2)
        {
        Stdio.printf("  FAIL two moves, in order, before the release (%d moves, %d in order)\n", gDrags, gOrderOK);
        fails = fails + (i32)1;
        }
    if (gUps != (i32)1 || gLastX != (i32)70 || gLastY != (i32)61)
        {
        Stdio.printf("  FAIL one release, where the pointer last was (%d at %d,%d)\n", gUps, gLastX, gLastY);
        fails = fails + (i32)1;
        }
    i32 drags = gDrags;
    i32 ups = gUps;
    gMadeUp = true;
    v.mouseDown(new UXEvent());
    if (!gMadeUpReturned || gDrags != drags || gUps != ups)
        {
        Stdio.printf("  FAIL a press the app makes up returns at once, with no moves or release\n");
        fails = fails + (i32)1;
        }
    if (fails == (i32)0)
        {
        Stdio.printf("PASS: trackMouse delivers a drag's moves and its release to the view\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", fails);
        }
    }
