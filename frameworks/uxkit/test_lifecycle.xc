// test_lifecycle.xc — one main() for every desktop backend (the *-lifecycle gates): the driver from
// UXPlatform, attached with UXApplication.setDriver, a window opened, and the run loop ended by
// app.stop() from the app's own frame clock (the turn hook), with no platform call.  Run again with
// UX_AUTOQUIT=<ms> and LIFECYCLE_NOSTOP=1, the loop ends by itself after that long.  UX_HEADLESS=1
// asks for setHeadless(true) first.  The source is the same on AppKit, GTK and Win32; the build
// names the backend only where the target does not (-D UX_GTK on a Mac).
#import <Stdio.xc>
#import "UXPlatform.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
u8* getenv(u8* name);

class Board : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)40, (i32)120, (i32)200);
        }
    }
UXApplication* gApp2;
i32 gTurns;
bool gNoStop;
void turn(void)
    {
    gTurns = gTurns + (i32)1;
    if (gTurns == (i32)10 && !gNoStop)
        {
        gApp2.stop();
        }
    }
class Delegate : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* w = new UXWindow();
        w.open((u8*)"lifecycle", UXGeom.make((i16)80, (i16)80, (i16)240, (i16)160), new Board());
        app.addWindow(w);
        w.displayAll();
        app.everyTurn(&turn, (i32)20);
        return (i32)0;
        }
    }
void main(void)
    {
    gNoStop = getenv((u8*)"LIFECYCLE_NOSTOP") != (u8*)0;
    UXApplication* app = new UXApplication();
    gApp2 = app;
    app.setDriver(UXPlatform.driver());
    if (getenv((u8*)"UX_HEADLESS") != (u8*)0)
        {
        app.setHeadless(true);
        }
    app.setDelegate(new Delegate());
    i32 t0 = gDriver.nowMs();
    i32 rc = app.run();
    i32 took = gDriver.nowMs() - t0;
    Stdio.printf("  (%s: run returned %d after %d turns, %d ms)\n", UXPlatform.name(), rc, gTurns, took);
    if (gNoStop)
        {
        Stdio.printf(rc == (i32)0 && gTurns > (i32)10 ? "PASS: UX_AUTOQUIT ended the run loop on %s\n" : "FAIL: UX_AUTOQUIT did not end the loop on %s\n", UXPlatform.name());
        }
    else
        {
        Stdio.printf(rc == (i32)0 && gTurns == (i32)10 ? "PASS: app.stop() from the turn hook ended the run loop on %s, one main() for every backend\n" : "FAIL: stop() did not end the loop on %s\n", UXPlatform.name());
        }
    }
