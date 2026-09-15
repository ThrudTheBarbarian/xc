// test_android_loop.xc — the `android-loop` gate: UXApplication.run(), ONE
// CALL in app code, on the backend where the platform owns the loop AND the
// program starts on a different thread.  run() detects the driver-owned loop
// and enters the shell (runLoop posts the start to the UI thread and parks
// xt_main's thread); applicationDidStart fires UI-side; three Handler-timed
// native clicks flow OnClickListener -> the bridge dex -> fire-by-peer ->
// the bound action; stop() ends the process from the fire path.  The app
// below is byte-identical in SHAPE to every other backend's loop test.
//
//   Build+run:  sh run_android_loop.sh
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXAndroidDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

extern void ux_and_test_click_later(i32 handle, i32 node, i32 ms);
extern void ux_and_test_watchdog(i32 ms, i32 rc);

i32 gTaps;

class Controller : Object<UXApplicationDelegate>
    {
    weak : UXApplication* app;
    UXWindow* win;
    UXButton* button;

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        Stdio.printf("loop: applicationDidStart (on the UI thread, via UXRun)\n");
        UXView* content = new UXView();
        win = new UXWindow();
        a.addWindow(win);
        win.open((u8*)"android loop", UXGeom.make((i16)0, (i16)0, (i16)320, (i16)240), content);
        button = new UXButton();
        button.setTitle((u8*)"Tap");
        button.setAction(&self.onTap);
        content.addSubview(button, UXGeom.make((i16)40, (i16)40, (i16)100, (i16)36));
        win.tree.finalise();
        win.displayAll(); // realizeTree: the REAL Button
        ux_and_test_click_later((i32)1, (i32)button.index, (i32)300);
        ux_and_test_click_later((i32)1, (i32)button.index, (i32)600);
        ux_and_test_click_later((i32)1, (i32)button.index, (i32)900);
        ux_and_test_watchdog((i32)15000, (i32)2); // a wedge FAILS, never hangs
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
    gDriver = new UXAndroidDriver(); // select the backend
    Controller* del = new Controller();
    app.setDelegate(del);
    app.run(); // hands the thread to the shell — never returns
    }
