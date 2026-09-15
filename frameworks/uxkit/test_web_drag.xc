// test_web_drag.xc — §3's THIRD blocking primitive, live: trackDragStep on
// the SAB ring (`web-drag`; the seam §5's scrollbar drags ride).
//
// The app is the shared loop shape: run() blocks in nextEvent; the harness
// pushes a mouse-down on the slider's knob, a stream of moves, and the
// release.  The down arrives through the ordinary dispatch into
// UXSlider.mouseDown, which then LOOPS IN trackDragStep — the worker
// blocking modally on the ring, exactly the collision the Worker design
// exists to survive — consuming the moves (value follows the pointer, one
// fire per step) until the release falls out.  Then a click on Stop ends
// the run, and the assertions want the whole story: the value tracked to
// the far end, and the action fired more than once (a drag, not a click).
//
//   Build+run:  sh run_web_drag.sh
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXWebDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXSlider.xc"
#import "UXGeometry.xc"

i32 gFires;
i32 gFinal;

class Controller : Object<UXApplicationDelegate>
    {
    weak : UXApplication* app;
    UXWindow* win;
    UXSlider* slider;

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        UXView* content = new UXView();
        win = new UXWindow();
        a.addWindow(win);
        // 0,0: one canvas IS the content area, so ring coordinates are window-local.
        win.open((u8*)"web drag", UXGeom.make((i16)0, (i16)0, (i16)320, (i16)200), content);
        slider = new UXSlider();
        slider.setRange((i32)0, (i32)100);
        slider.setValue((i32)0);
        slider.setAction(&self.onSlide);
        content.addSubview(slider, UXGeom.make((i16)10, (i16)60, (i16)200, (i16)20));
        UXButton* b = new UXButton();
        b.setTitle((u8*)"Stop");
        b.setAction(&self.onStop);
        content.addSubview(b, UXGeom.make((i16)40, (i16)120, (i16)80, (i16)24));
        win.tree.finalise();
        win.displayAll();
        Stdio.printf("drag: window up, waiting on the ring\n");
        return (i32)0;
        }
    void onSlide(UXControl* sender)
        {
        gFires = gFires + (i32)1;
        }
    void onStop(UXControl* sender)
        {
        gFinal = slider.intValue();
        Stdio.printf("drag: released at value=%d after %d fires\n", gFinal, gFires);
        app.stop();
        }
    }

    void
    main(void)
    {
    gFires = (i32)0;
    gFinal = (i32)0;
    UXApplication* app = new UXApplication();
    app.setDriver(new UXWebDriver());
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run(); // blocks in nextEvent — Worker territory
    // >= 80: the drag reached the track's far end; > 2 fires: it MOVED there
    // step by step through trackDragStep, it didn't jump on the down-click.
    Stdio.printf(gFinal >= (i32)80 && gFires > (i32)2
                     ? "PASS: trackDragStep blocked on the ring and the value followed the drag\n"
                     : "FAIL: 1\n");
    }
