// test_gtk_loop.xc — the neutral RUN LOOP native on GTK4 (the `gtk-loop`
// gate).  test_gtk_real.xc proved paint + native fire but drove the clicks
// by hand; this runs the whole thing under UXApplication.run() — the SAME
// loop the GEM/Win32/AppKit apps use.  nextEvent SLEEPS in the GMainContext;
// three timer-scheduled native "clicked" emissions arrive through that wait,
// fire-by-peer runs the bound action inline, and stop() ends the loop from
// the fire path.  Nothing in the app is GTK-aware except selecting the
// backend and the timer lines.
//
//   Build+run:  sh run_gtk_loop.sh
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

extern void ux_gtk_test_click_later(i32 handle, i32 node, i32 ms);
extern void ux_gtk_test_watchdog(i32 ms, i32 rc);

i32 gTaps;

class Controller : Object<UXApplicationDelegate>
    {
    weak : UXApplication* app;
    UXWindow* win;
    UXButton* button;

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        Stdio.printf("loop: applicationDidStart\n");
        UXView* content = new UXView();
        win = new UXWindow();
        a.addWindow(win);
        win.open((u8*)"gtk loop", UXGeom.make((i16)0, (i16)0, (i16)320, (i16)240), content);
        button = new UXButton();
        button.setTitle((u8*)"Tap");
        button.setAction(&self.onTap);
        content.addSubview(button, UXGeom.make((i16)40, (i16)40, (i16)100, (i16)36));
        win.tree.finalise();
        win.displayAll(); // realizeTree: the REAL GtkButton
        ux_gtk_test_click_later((i32)1, (i32)button.index, (i32)200);
        ux_gtk_test_click_later((i32)1, (i32)button.index, (i32)400);
        ux_gtk_test_click_later((i32)1, (i32)button.index, (i32)600);
        ux_gtk_test_watchdog((i32)15000, (i32)2); // a wedge FAILS, never hangs
        return (i32)0;
        }
    void onTap(UXControl* sender)
        {
        gTaps = gTaps + (i32)1;
        Stdio.printf("loop: native tap %d -> bound action\n", (i16)gTaps);
        // run()'s loop exits normally
        if (gTaps == (i32)3)
            {
            app.stop();
            }
        }
    }

    void
    main(void)
    {
    gTaps = (i32)0;
    gDriver = new UXGtkDriver(); // select the backend
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display for gtk_init\n");
        return;
        }
    Controller* del = new Controller();
    UXApplication* app = new UXApplication();
    app.setDelegate(del);
    i32 rc = app.run(); // boot -> didStart -> the SLEEPING pump loop
    Stdio.printf("stopped rc=%d taps=%d\n", rc, gTaps);
    Stdio.printf(gTaps == (i32)3 ? "PASS: run() sleeps in the GMainContext and native fires drive the app\n"
                                 : "FAIL: 1\n");
    }
