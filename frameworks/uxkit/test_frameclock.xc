// test_frameclock.xc — the app's frame clock (UXApplication.everyTurn).
//
// A live app needs a turn: a moment that comes round on its own, with no input and outside any
// draw, where it can step a simulation and mark what moved.  everyTurn(fn, ms) is that hook.  WHO
// calls fn is the driver's answer (UXViewDriver.setTurnHook): true where the driver owns the loop
// and arms its own source, false where the neutral loop paces itself and the ms becomes the
// deadline it hands nextEvent.  This gate is the neutral-loop half of that contract, run headless
// on AppKit — there the driver answers false, so everything below is the loop's own work.
//
// It checks the four things a client depends on:
//   1. turns arrive at all, driven by nothing but the clock;
//   2. at the cadence asked for — not faster, and not on some slower default poll;
//   3. input is not starved: a click queued between turns is still dispatched;
//   4. the caller is told which clock it got (turnIsDriven()).
//
//   Build+run:  sh run_frameclock.sh
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

i32 gTurns;
i32 gFirstMs;
i32 gLastMs;
i32 gClicked;
i32 gWinHandle;

#define TURN_MS 16
#define WANT_TURNS 14
#define CLICK_AT_TURN 3
// The click arrives as more than one queued event and those turns return with no wait at all, so
// the cadence is measured over the turns AFTER it, where the clock is the only thing driving.
#define MEASURE_FROM 6

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

// The hook.  A PLAIN argument-less function — the shape every backend can hold, because AppKit,
// iOS and Android keep a C function pointer and nothing a closure could ride on — so the gate
// passes it in exactly the shape a client's game loop would.
void tickFn(void)
    {
    gTurns = gTurns + (i32)1;
    if (gTurns == (i32)MEASURE_FROM)
        {
        gFirstMs = gDriver.nowMs();
        }
    if (gTurns >= (i32)MEASURE_FROM)
        {
        gLastMs = gDriver.nowMs();
        }
    if (gTurns == (i32)CLICK_AT_TURN)
        {
        // Queued between turns: if the deadline starved input, this would never be dispatched.
        ux_ak_post_click(gWinHandle, (i32)30, (i32)40);
        }
    if (gTurns >= (i32)WANT_TURNS)
        {
        // Stopping the clock and the app from inside a turn: neither must be deferred to the next
        // one, or a game that wants to quit on a turn would need an input event to notice.
        gApp.everyTurn((turnHook_t*)0, (i32)0);
        gApp.stop();
        }
    }

class Delegate : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* win = new UXWindow();
        Canvas* canvas = new Canvas();
        win.open((u8*)"UXKit", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)120), canvas);
        app.addWindow(win);
        gWinHandle = win.handle;
        // Ask for the clock BEFORE the loop starts, the way a client's didStart would.
        app.everyTurn(&tickFn, (i32)TURN_MS);
        Stdio.printf("clock: asked for %dms; driven=%d\n", (i32)TURN_MS, app.turnIsDriven() ? (i32)1 : (i32)0);
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
    gDriver = new UXAppKitDriver();
    Delegate* del = new Delegate();
    UXApplication* app = new UXApplication();
    app.setDelegate(del);
    i32 rc = app.run();
    i32 spans = (i32)WANT_TURNS - (i32)MEASURE_FROM; // intervals actually measured
    i32 elapsed = gLastMs - gFirstMs;
    // Faster than the clock asked for means the wait is not being made (a spin); slower than twice
    // it means the deadline is not the one coming back (the toolkit's default poll is 50ms, and a
    // run of these at 50ms would land far above this ceiling).
    i32 lo = spans * (TURN_MS - (i32)7);
    i32 hi = spans * (TURN_MS + (i32)18);
    Stdio.printf("clock: rc=%d turns=%d measured=%dms/%d intervals clicked=%d driven=%d\n",
                 rc, gTurns, elapsed, spans, gClicked, app.turnIsDriven() ? (i32)1 : (i32)0);
    bool ok = true;
    if (gTurns < (i32)WANT_TURNS) { Stdio.printf("FAIL: turns\n"); ok = false; }
    if (gClicked < (i32)1) { Stdio.printf("FAIL: click starved by the deadline\n"); ok = false; }
    if (elapsed < lo || elapsed > hi)
        {
        Stdio.printf("FAIL: cadence (want %d..%d)\n", lo, hi);
        ok = false;
        }
    if (app.turnIsDriven()) { Stdio.printf("FAIL: headless AppKit should pace itself\n"); ok = false; }
    if (ok)
        {
        Stdio.printf("PASS: the neutral loop turns the app's clock at the cadence it asked for\n");
        }
    }
