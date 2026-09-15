// test_appkit_interactive.xc — the INTERACTIVE dispatch path, automated.
//
// Runs the real interactive stack ([NSApp run] owns the loop, the content view forwards events),
// then injects one synthetic click at a Quit button.  The click must travel AppKit -> the content
// view's mouseDown: -> the dispatch trampoline -> UXApplication.dispatchEvent -> the toolkit's
// hit-test -> the button's action -> app.stop() -> [NSApp run] returns.  If the app quits, the whole
// interactive chain works (and doesn't hang).  macOS-only.
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
        ux_ak_post_click(win.handle, (i32)40, (i32)52); // inject a click inside the Quit button
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
    Stdio.printf(gFired == (i32)1 ? "PASS: interactive click -> button action -> quit\n"
                                  : "FAIL: click did not reach the button\n");
    }
