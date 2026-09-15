// test_appkit_loop.xc — the neutral RUN LOOP native on AppKit.
//
// test_appkit_real.xc proved the neutral view layer paints and hit-tests on AppKit but drove the
// clicks by hand.  This runs the whole thing under UXApplication.run() — the SAME loop the GEM and
// Win32 apps use — pumping the REAL NSApplication event queue: a posted mouse-down travels
// driver.nextEvent (nextEventMatchingMask -> decode) -> UXApplication.dispatchEvent -> the window ->
// UXView.mouseDown, and a posted quit ends the loop.  Nothing in the app is AppKit-aware except
// selecting the backend and the one line that simulates the OS delivering a click.
//
//   Build+run:  sh run_appkit_loop.sh   (xtc -A arm64 + the ObjC shim, native; no window shown)
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

// ux_ak_post_click / ux_ak_post_quit come in via UXAppKitDriver.xc.
i32 gLoopClicked;

class Canvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)10, (i16)10, (i16)50, (i16)30), (i32)8);
        }
    bool acceptsFirstResponder(void)
        {
        return true;
        }
    void mouseDown(UXEvent* e)
        {
        gLoopClicked = gLoopClicked + (i32)1;
        Stdio.printf("loop-mouseDown=%d,%d\n", (i32)e.x, (i32)e.y);
        }
    }

    class Delegate : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        Stdio.printf("start\n");
        UXWindow* win = new UXWindow();
        Canvas* canvas = new Canvas();
        win.open((u8*)"UXKit", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)120), canvas);
        app.addWindow(win); // so dispatchEvent can find it by handle

        // Simulate the OS delivering a click at (30,40), then ask the loop to quit.  Both go through
        // the real NSApplication queue; the neutral loop pumps them via nextEvent — we do NOT call
        // dispatchMouse ourselves.
        ux_ak_post_click(win.handle, (i32)30, (i32)40);
        ux_ak_post_quit();
        return (i32)0; // 0 = keep running; the loop takes over
        }
    }

    void
    main(void)
    {
    gLoopClicked = (i32)0;
    gDriver = new UXAppKitDriver(); // select the backend
    Delegate* del = new Delegate();
    UXApplication* app = new UXApplication();
    app.setDelegate(del);
    i32 rc = app.run(); // boot -> applicationDidStart -> the pump loop
    Stdio.printf("stopped rc=%d clicked=%d\n", rc, gLoopClicked);
    Stdio.printf(gLoopClicked >= (i32)1 ? "PASS: the neutral run loop pumps AppKit events into an UXView\n" : "FAIL\n");
    }
