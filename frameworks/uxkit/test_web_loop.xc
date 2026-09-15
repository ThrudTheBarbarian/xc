// test_web_loop.xc — the design doc's `web-loop` milestone (§5):
// UXApplication.run() pumping the SAB ring through nextEvent -> dispatchEvent
// -> mouseDown -> a bound action.  The run loop is BYTE-IDENTICAL to every
// other backend — main() blocks in nextEvent, which is the whole point of the
// Worker (§3): under Node the harness runs this module in a worker_thread and
// the parent pushes a click into the ring from outside.
//
//   Build+run:  sh run_web_loop.sh
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXWebDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

i32 gFired;

class Controller : Object<UXApplicationDelegate>
    {
    weak : UXApplication* app;
    UXWindow* win;

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        UXView* content = new UXView();
        win = new UXWindow();
        a.addWindow(win);
        // 0,0: one canvas IS the content area, so ring coordinates are window-local.
        win.open((u8*)"web loop", UXGeom.make((i16)0, (i16)0, (i16)320, (i16)200), content);
        UXButton* b = new UXButton();
        b.setTitle((u8*)"Stop");
        b.setAction(&self.onStop);
        content.addSubview(b, UXGeom.make((i16)40, (i16)40, (i16)80, (i16)24));
        win.tree.finalise();
        win.displayAll();
        Stdio.printf("loop: window up, waiting on the ring\n");
        return (i32)0;
        }
    void onStop(UXControl* sender)
        {
        gFired = gFired + (i32)1;
        Stdio.printf("loop: action fired via the ring\n");
        app.stop();
        }
    }

    void
    main(void)
    {
    gFired = (i32)0;
    UXApplication* app = new UXApplication();
    app.setDriver(new UXWebDriver());
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run(); // blocks in nextEvent — Worker territory
    Stdio.printf(gFired >= (i32)1
                     ? "PASS: run() pumped the SAB ring to a bound action\n"
                     : "FAIL: 1\n");
    }
