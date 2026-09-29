// test_win32_frameclock.xc — the app's frame clock on the Win32 backend, under Wine.
//
// test_frameclock.xc gates the neutral half of UXApplication.everyTurn on headless AppKit, where
// nextEvent polls.  Win32 is the other shape: nextEvent BLOCKS, in GetMessageA, so a deadline has
// to be a different call — MsgWaitForMultipleObjects with the clock's ms, and an empty turn when
// the deadline wins.  This is the gate for that path: if the wait were not honoured the loop would
// spin through its turns in no time at all, and if it blocked forever the app would never quit.
//
//   Build+run:  sh run_win32_frameclock.sh   (xtc -A win64 -> .exe, run under Wine; needs wine)
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWin32.h.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

#define TURN_MS 16
#define CLICK_AT_TURN 4
#define CLOCK_TURNS 8

i32 gTurns;
i32 gFirstMs;
i32 gLastMs;
i32 gClicked;
pointer gHwnd;

class Canvas : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        }
    bool acceptsFirstResponder(void)
        {
        return true;
        }
    void mouseDown(UXEvent* e)
        {
        gClicked = gClicked + (i32)1;
        }
    }

// A PLAIN argument-less function: the driver holds it as a C function pointer.
void tickFn(void)
    {
    gTurns = gTurns + (i32)1;
    if (gTurns == (i32)1)
        {
        gFirstMs = gDriver.nowMs();
        }
    gLastMs = gDriver.nowMs();
    if (gTurns == (i32)CLICK_AT_TURN)
        {
        // Between two turns: an input event must not be starved by the deadline.
        u32 lp = ((u32)40 << (u32)16) | (u32)30;
        PostMessageA(gHwnd, (u32)WM_LBUTTONDOWN, (pointer)0, (pointer)lp);
        }
    if (gTurns >= (i32)CLOCK_TURNS)
        {
        // Stopping the clock, then the app, both from inside a turn.
        gApp.everyTurn((turnHook_t*)0, (i32)0);
        gApp.stop();
        }
    }

class Delegate : Object<UXApplicationDelegate>
    {
    UXWin32Driver* drv;
    void setDriver(UXWin32Driver* d)
        {
        drv = d;
        }

    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* win = new UXWindow();
        Canvas* canvas = new Canvas();
        win.open((u8*)"UXKit", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)120), canvas);
        app.addWindow(win);
        gHwnd = drv.windowNative(win.handle);
        app.everyTurn(&tickFn, (i32)TURN_MS);
        Stdio.printf("clock: driven=%d\n", app.turnIsDriven() ? (i32)1 : (i32)0);
        return (i32)0;
        }
    }

    void
    main(void)
    {
    gTurns = (i32)0;
    gFirstMs = (i32)0;
    gLastMs = (i32)0;
    gClicked = (i32)0;
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    Delegate* del = new Delegate();
    del.setDriver(d);
    UXApplication* app = new UXApplication();
    app.setDelegate(del);
    i32 rc = app.run();
    i32 elapsed = gLastMs - gFirstMs;
    Stdio.printf("clock: turns=%d clicked=%d\n", gTurns, gClicked);
    // A spin through the turns would take no time at all; a blocking wait would never quit.
    if (gTurns == (i32)CLOCK_TURNS && gClicked == (i32)1 && elapsed >= (i32)40)
        {
        Stdio.printf("PASS: the Win32 deadline ends the wait and the turn comes round\n");
        }
    else
        {
        Stdio.printf("FAIL: the Win32 frame clock\n");
        }
    }
