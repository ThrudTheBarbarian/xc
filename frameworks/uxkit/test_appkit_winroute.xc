// test_appkit_winroute.xc — a click on the SECOND window must route to the second window's view, not
// the first.  The sibling of test_win32_winroute.xc, and there for the same reason: the neutral
// dispatchEvent only asks the driver to resolve a point when the event carries no window handle,
// which is exactly the headless posted-click path — and the old windowAtPoint stub answered window 1
// for every point.
//
// AppKit answers it natively: the NSEvent says which window it was for, so the shim records that when
// the neutral loop pulls the click.  (The interactive path already gets the same answer from the
// content view that received the press.)  Two windows, each a self-drawn view; post a click to window
// 2 and check which view's mouseDown fired.
//
//   Build+run:  sh run_appkit_winroute.sh   (xtc -A arm64 + the ObjC shim, native; no window shown)
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

// ux_ak_post_click / ux_ak_post_quit come in via UXAppKitDriver.xc.
i32 gClicked1;
i32 gClicked2;

class ClickView : UXView
    {
    i32 which;
    void init(void)
        {
        super.init();
        which = (i32)0;
        }
    void mouseDown(UXEvent* e)
        {
        if (self.which == (i32)1)
            {
            gClicked1 = gClicked1 + (i32)1;
            }
        else
            {
            gClicked2 = gClicked2 + (i32)1;
            }
        Stdio.printf("mouseDown in window %d at %d,%d\n", (i32)self.which, (i32)e.x, (i32)e.y);
        }
    }

    class Delegate : Object<UXApplicationDelegate>
    {
    UXWindow* w2;

    // One window: a plain content view with a ClickView filling it.
    void addClickWindow(UXApplication* app, i32 which, UXGeom frame)
        {
        UXWindow* w = new UXWindow();
        UXView* content = new UXView();
        w.open(which == (i32)1 ? (u8*)"One" : (u8*)"Two", frame, content);
        app.addWindow(w); // so dispatchEvent can find it by handle
        ClickView* v = new ClickView();
        v.which = which;
        content.addSubview(v, UXGeom.make((i16)0, (i16)0, (i16)200, (i16)150));
        w.tree.finalise();
        w.displayAll();
        if (which == (i32)2)
            {
            self.w2 = w;
            }
        }

    i32 applicationDidStart(UXApplication* app)
        {
        Stdio.printf("start\n");
        self.addClickWindow(app, (i32)1, UXGeom.make((i16)20, (i16)20, (i16)200, (i16)150));
        self.addClickWindow(app, (i32)2, UXGeom.make((i16)260, (i16)20, (i16)200, (i16)150));

        // Simulate the OS delivering a click squarely inside window 2, then ask the loop to quit.  Both
        // go through the real NSApplication queue and the neutral loop pumps them via nextEvent.
        ux_ak_post_click(self.w2.handle, (i32)50, (i32)50);
        ux_ak_post_quit();
        return (i32)0; // 0 = keep running; the loop takes over
        }
    }

    void
    main(void)
    {
    gClicked1 = (i32)0;
    gClicked2 = (i32)0;
    gDriver = new UXAppKitDriver(); // select the backend
    Delegate* del = new Delegate();
    UXApplication* app = new UXApplication();
    app.setDelegate(del);
    i32 rc = app.run(); // boot -> applicationDidStart -> the pump loop
    Stdio.printf("stopped rc=%d clicked1=%d clicked2=%d\n", rc, gClicked1, gClicked2);
    if (gClicked1 == (i32)0 && gClicked2 == (i32)1)
        {
        Stdio.printf("PASS: the click routed to the window it was posted to\n");
        }
    else
        {
        Stdio.printf("FAIL\n");
        }
    }
