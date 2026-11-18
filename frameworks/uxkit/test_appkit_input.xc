// test_appkit_input.xc — what AppKit's input reaches the toolkit as: the modifier keys on a press,
// the middle button as its own kind, a key's release, and the keys with no character as the
// toolkit's codes.  The events are built as AppKit builds them and handed to the window's content
// view (ux_ak_test_input), headless.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"

i32 ux_ak_test_input(i32 handle, i32 kind, i32 x, i32 y, i32 mods, i32 ch);
void ux_ak_test_release_after(i32 handle, i32 ms);

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }

// Records the last event of each kind it heard.
class Recorder : UXView
    {
    i32 heard;
    i32 heardMods;
    i32 buttons;
    i32 key;
    i32 count;
    i32 held;
    i32 ups;
    bool tracks;
    i32 wheelDY;
    i32 wheelDX;
    i32 scale;
    void note(UXEvent* e)
        {
        heard = (i32)e.kind;
        heardMods = (i32)e.modifiers;
        buttons = (i32)e.buttons;
        key = (i32)e.key;
        count = count + (i32)1;
        }
    bool acceptsFirstResponder(void)
        {
        return true;
        }
    void mouseDown(UXEvent* e)
        {
        self.note(e);
        if (tracks)
            {
            self.trackMouse(e);
            }
        }
    i32 holdDelay(void)
        {
        return tracks ? (i32)150 : (i32)0;
        }
    void mouseHeld(UXEvent* e)
        {
        held = held + (i32)1;
        }
    void mouseUp(UXEvent* e)
        {
        ups = ups + (i32)1;
        }
    void rightMouseDown(UXEvent* e)
        {
        self.note(e);
        }
    void otherMouseDown(UXEvent* e)
        {
        self.note(e);
        }
    void keyDown(UXEvent* e)
        {
        self.note(e);
        }
    void keyUp(UXEvent* e)
        {
        self.note(e);
        }
    void scrollWheel(UXEvent* e)
        {
        self.note(e);
        wheelDY = e.b;
        wheelDX = e.dx;
        }
    void magnify(UXEvent* e)
        {
        self.note(e);
        scale = e.a;
        }
    }

class Controller : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        UXView* content = new UXView();
        UXWindow* win = new UXWindow();
        win.open((u8*)"Input", UXGeom.make((i16)80, (i16)80, (i16)240, (i16)160), content);
        app.addWindow(win);
        Recorder* r = new Recorder();
        content.addSubview(r, UXGeom.make((i16)0, (i16)0, (i16)240, (i16)160));
        win.tree.finalise();
        win.displayAll();
        i32 h = win.handle;

        Stdio.printf("-- presses\n");
        ux_ak_test_input(h, (i32)1, (i32)40, (i32)40, (i32)UX_MOD_SHIFT, (i32)0);
        check("a shift-click is a press", r.heard, (i32)UXEventMouseDown);
        check("  with Shift", (r.heardMods & (i32)UX_MOD_SHIFT) == (i32)UX_MOD_SHIFT ? (i32)1 : (i32)0, (i32)1);
        check("  of the left button", r.buttons, (i32)UX_BUTTON_LEFT);
        ux_ak_test_input(h, (i32)1, (i32)40, (i32)40, (i32)UX_MOD_CMD, (i32)0);
        check("a Command-click carries Command", r.heardMods, (i32)UX_MOD_CMD);
        check("  which is the command key here", (i32)gUXCommandModifier, (i32)UX_MOD_CMD);
        ux_ak_test_input(h, (i32)18, (i32)40, (i32)40, (i32)0, (i32)0);
        check("the middle button is its own kind", r.heard, (i32)UXEventOtherMouseDown);
        check("  of the middle button", r.buttons, (i32)UX_BUTTON_MIDDLE);
        ux_ak_test_input(h, (i32)16, (i32)40, (i32)40, (i32)(UX_MOD_SHIFT | UX_MOD_ALT), (i32)0);
        check("a right press carries Shift and Option", (r.heardMods & (i32)(UX_MOD_ALT | UX_MOD_SHIFT)) == (i32)(UX_MOD_ALT | UX_MOD_SHIFT) ? (i32)1 : (i32)0, (i32)1);
        check("  of the right button", r.buttons, (i32)UX_BUTTON_RIGHT);

        Stdio.printf("-- keys\n");
        ux_ak_test_input(h, (i32)1, (i32)40, (i32)40, (i32)0, (i32)0); // focus the recorder
        ux_ak_test_input(h, (i32)4, (i32)0, (i32)0, (i32)0, (i32)'a');
        check("a typed key", r.key, (i32)'a');
        ux_ak_test_input(h, (i32)4, (i32)0, (i32)0, (i32)0, (i32)$F702); // NSLeftArrowFunctionKey
        check("the left arrow as the toolkit's code", r.key, (i32)UX_KEY_LEFT);
        ux_ak_test_input(h, (i32)17, (i32)0, (i32)0, (i32)UX_MOD_SHIFT, (i32)$F702);
        check("its release is a key up", r.heard, (i32)UXEventKeyUp);
        check("  with the same code", r.key, (i32)UX_KEY_LEFT);
        check("  and Shift", (r.heardMods & (i32)UX_MOD_SHIFT) == (i32)UX_MOD_SHIFT ? (i32)1 : (i32)0, (i32)1);
        ux_ak_test_input(h, (i32)4, (i32)0, (i32)0, (i32)0, (i32)$7F); // the delete key above return
        check("delete is Backspace", r.key, (i32)UX_KEY_BACKSPACE);
        ux_ak_test_input(h, (i32)4, (i32)0, (i32)0, (i32)0, (i32)$1B);
        check("escape", r.key, (i32)UX_KEY_ESCAPE);

        Stdio.printf("-- the trackpad\n");
        // 12 px down (AppKit: -12, scrolling down) and 20 px right (AppKit: -20)
        ux_ak_test_input(h, (i32)11, (i32)40, (i32)40, (i32)((-5) & 255) << 8, (i32)-12);
        check("a scroll is a wheel event", r.heard, (i32)UXEventWheel);
        check("  its vertical delta, positive down", r.wheelDY, (i32)12);
        check("  its horizontal delta, positive right", r.wheelDX, (i32)20);
        ux_ak_test_input(h, (i32)19, (i32)40, (i32)40, (i32)0, (i32)150);
        check("a pinch is a magnify event", r.heard, (i32)UXEventMagnify);
        check("  its change in scale, in thousandths", r.scale, (i32)150);
        ux_ak_test_input(h, (i32)19, (i32)40, (i32)40, (i32)0, (i32)-80);
        check("  and a pinch inward", r.scale, (i32)-80);

        Stdio.printf("-- a long press\n");
        r.tracks = true;
        ux_ak_test_release_after(h, (i32)500); // the release comes 500 ms after the press
        ux_ak_test_input(h, (i32)1, (i32)40, (i32)40, (i32)0, (i32)0);
        check("a press held still past holdDelay is mouseHeld", r.held, (i32)1);
        check("  and is followed to its release", r.ups, (i32)1);
        r.tracks = false;

        ux_ak_post_quit();
        return (i32)0;
        }
    }
void main(void)
    {
    Controller* c = new Controller();
    UXApplication* app = new UXApplication();
    app.setDriver(new UXAppKitDriver());
    app.setHeadless(true);
    app.setDelegate(c);
    app.run();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: AppKit input -- modifiers, the middle button, key releases, key codes\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", gFails);
        }
    }
