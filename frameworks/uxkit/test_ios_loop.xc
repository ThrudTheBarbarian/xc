// test_ios_loop.xc — the `ios-loop` gate: UXApplication.run(), ONE CALL in app
// code, on the backend where the platform owns the loop.  run() detects the
// driver-owned loop and enters the shell; applicationDidStart fires from
// didFinishLaunching; three self-injected NATIVE taps flow UIKit target-action
// -> fire-by-peer -> the bound action; stop() ends the process from the fire
// path.  The app below is byte-identical in SHAPE to every other backend's
// loop test — that was the whole point of the spiked decision.
//
//   Build+run:  sh run_ios_loop.sh
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXIosDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

extern void ux_ios_test_tap_later(i32 handle, i32 x, i32 y, i32 ms);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);

i32 gTaps;

class Controller : Object<UXApplicationDelegate>
    {
    weak : UXApplication* app;
    UXWindow* win;

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        Stdio.printf("loop: applicationDidStart (from didFinishLaunching)\n");
        UXView* content = new UXView();
        win = new UXWindow();
        a.addWindow(win);
        win.open((u8*)"ios loop", UXGeom.make((i16)0, (i16)0, (i16)320, (i16)240), content);
        UXButton* b = new UXButton();
        b.setTitle((u8*)"Tap");
        b.setAction(&self.onTap);
        content.addSubview(b, UXGeom.make((i16)40, (i16)40, (i16)100, (i16)36));
        win.tree.finalise();
        win.displayAll(); // realizeTree: the REAL UIButton
        ux_ios_test_tap_later((i32)1, (i32)90, (i32)58, (i32)300);
        ux_ios_test_tap_later((i32)1, (i32)90, (i32)58, (i32)600);
        ux_ios_test_tap_later((i32)1, (i32)90, (i32)58, (i32)900);
        ux_ios_test_watchdog((i32)15000, (i32)2); // a wedge FAILS, never hangs
        return (i32)0;
        }
    void onTap(UXControl* sender)
        {
        gTaps = gTaps + (i32)1;
        Stdio.printf("loop: native tap %d -> bound action\n", (i16)gTaps);
        if (gTaps == (i32)3)
            {
            Stdio.printf("PASS: run() on the driver-owned loop — start, three native taps, stop\n");
            app.stop(); // the fire path quits(0)
            }
        }
    }

    void
    main(void)
    {
    gTaps = (i32)0;
    UXApplication* app = new UXApplication();
    app.setDriver(new UXIosDriver()); // the ONE iOS-aware line
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run();                              // enters the shell; never returns
    Stdio.printf("FAIL: run() returned\n"); // unreachable on iOS by design
    }
