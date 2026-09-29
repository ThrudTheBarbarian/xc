// test_appkit_interactive.xc — the INTERACTIVE dispatch path, automated.
//
// Runs the real interactive stack ([NSApp run] owns the loop, the content view forwards events),
// then injects one synthetic click at a Quit button.  The click must travel AppKit -> the content
// view's mouseDown: -> the dispatch trampoline -> UXApplication.dispatchEvent -> the toolkit's
// hit-test -> the button's action -> app.stop() -> [NSApp run] returns.  If the app quits, the whole
// interactive chain works (and doesn't hang).  macOS-only.
//
// The click is injected FROM A TURN: this is the other half of the frame-clock contract, the shape
// where the driver answers setTurnHook with true because [NSApp run] owns the thread and nothing
// above the driver would ever get a turn otherwise.  So the gate proves both at once -- the driver's
// own turn source fires, and a click it injects still travels the whole interactive chain.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

i32 gFired;
i32 gTurns;
i32 gWinHandle;
#define CLICK_AT_TURN 2

// The hook: a plain argument-less function, the only shape a C-held pointer can carry.
void tickFn(void)
    {
    gTurns = gTurns + (i32)1;
    if (gTurns == (i32)CLICK_AT_TURN)
        {
        ux_ak_post_click(gWinHandle, (i32)40, (i32)52); // inject a click inside the Quit button
        }
    }

class Canvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)0, (i16)0, (i16)200, (i16)120), (i32)8);
        }
    bool acceptsFirstResponder(void)
        {
        return true;
        }
    } class Ctl : Object<UXApplicationDelegate>
    {
    UXApplication* app;
    void onQuit(UXControl* c)
        {
        gFired = (i32)1;
        Stdio.printf("quit button fired\n");
        app.stop();
        }
    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        UXWindow* win = new UXWindow();
        Canvas* canvas = new Canvas();
        win.open((u8*)"t", UXGeom.make((i16)60, (i16)60, (i16)200, (i16)120), canvas);
        app.addWindow(win);
        UXButton* b = new UXButton();
        b.setTitle((u8*)"Quit");
        b.setAction(&self.onQuit);
        canvas.addSubview(b, UXGeom.make((i16)20, (i16)40, (i16)80, (i16)26));
        win.displayAll();
        gWinHandle = win.handle;
        // Ask for a turn.  Interactive AppKit answers true and arms its own timer, so the click
        // above comes from the driver's turn rather than from the start-up path.
        a.everyTurn(&tickFn, (i32)16);
        Stdio.printf("interactive: driven=%d\n", a.turnIsDriven() ? (i32)1 : (i32)0);
        return (i32)0;
        }
    } void main(void)
    {
    gFired = (i32)0;
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true);
    Ctl* c = new Ctl();
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    app.setDelegate(c);
    app.run();
    Stdio.printf("interactive: turns=%d fired=%d\n", gTurns, gFired);
    Stdio.printf((gFired == (i32)1 && gTurns >= (i32)CLICK_AT_TURN)
                     ? "PASS: the driver's own turn injected the click -> button action -> quit\n"
                     : "FAIL: the turn-driven click did not reach the button\n");
    }
