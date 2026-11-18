// test_web_hold.xc — a long press on the web: a view whose holdDelay is 300 ms follows its press
// with trackMouse; held still for longer, mouseHeld fires once, where the pointer is, and the drag
// goes on to the release; a press that moves away first is not held.  The gesture is scripted on
// the ring by run_web_hold.mjs, with real time between its records.
//
//   Build+run:  sh run_web_hold.sh
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXWebDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"

i32 gHeld;    // mouseHeld calls
i32 gHeldX;
i32 gUps;     // presses followed to their release
i32 gHeldOn;  // which press was held (1 or 2)

class HoldView : UXView
    {
    weak : UXApplication* app;
    i32 holdDelay(void)
        {
        return (i32)300;
        }
    void mouseDown(UXEvent* e)
        {
        self.trackMouse(e);
        }
    void mouseHeld(UXEvent* e)
        {
        gHeld = gHeld + (i32)1;
        gHeldX = (i32)e.x;
        gHeldOn = gUps + (i32)1;
        }
    void mouseUp(UXEvent* e)
        {
        gUps = gUps + (i32)1;
        if (gUps == (i32)2)
            {
            app.stop();
            }
        }
    }

class Controller : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* a)
        {
        HoldView* v = new HoldView();
        v.app = a;
        UXWindow* win = new UXWindow();
        a.addWindow(win);
        win.open((u8*)"hold", UXGeom.make((i16)0, (i16)0, (i16)320, (i16)200), v);
        win.displayAll();
        Stdio.printf("hold: window up, waiting on the ring\n");
        return (i32)0;
        }
    }
void main(void)
    {
    UXApplication* app = new UXApplication();
    app.setDriver(new UXWebDriver());
    app.setDelegate(new Controller());
    app.run();
    bool ok = gHeld == (i32)1 && gHeldOn == (i32)1 && gHeldX == (i32)51 /* the twitch's point, within the slop */ && gUps == (i32)2;
    Stdio.printf(ok ? "PASS: a press held still past holdDelay is mouseHeld, once; one that moves away is not\n"
                    : "FAIL: held=%d on press %d at x=%d, releases=%d\n", gHeld, gHeldOn, gHeldX, gUps);
    }
