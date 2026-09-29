// demo_appkit_scrollpanel.xc — a NATIVE control inside a scroll view moves with it.
//
// A native control is created as a flat child of the window's content view, so a control inside a
// scroll view's document used to stay put when the scroll moved and was not clipped to it.  The
// realizeTree re-parent pass moves each such control into the scroll's DOCUMENT view; the gate SEES
// the move happen (the shim counts it).  Headless there are no native controls at all, so nothing
// moves -- asserted too, because a count that went up with no window would be the bug.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"
#import "demo_autoquit.xc"

u8* getenv(u8* name);
i32 ux_ak_reparent_count(void); // libUXAppKit.m: controls the re-parent pass has moved

i32 gFails = 0;
void ck(bool ok, u8* what)
    {
    if (!ok)
        {
        Stdio.printf("  no: %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

class Controller : Object<UXApplicationDelegate>
    {
    UXApplication* app;
    UXWindow* win;
    UXScrollView* scroll;
    UXButton* deep;

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        bool headless = getenv((u8*)"UX_GL_HEADLESS") != (u8*)0;

        UXView* canvas = new UXView();
        win = new UXWindow();
        win.open((u8*)"UXKit scroll panel", UXGeom.make((i16)160, (i16)160, (i16)280, (i16)220), canvas);

        scroll = new UXScrollView();
        canvas.addSubview(scroll, UXGeom.make((i16)10, (i16)10, (i16)260, (i16)200));
        scroll.setDocumentHeight((i32)900); // taller than the scroll: it must scroll

        // A native button DEEP in the document, below the fold: unreachable unless it scrolls.
        deep = new UXButton();
        deep.setTitle((u8*)"Deep");
        scroll.document().addSubview(deep, UXGeom.make((i16)20, (i16)700, (i16)120, (i16)28));

        win.displayAll();

        if (headless)
            {
            ck(ux_ak_reparent_count() == (i32)0, "no window -> no native control, so nothing moved");
            Stdio.printf("  reparented=%d (headless)\n", ux_ak_reparent_count());
            app.stop();
            }
        else
            {
            ck(ux_ak_reparent_count() > (i32)0, "a native control inside the scroll moved into its document view");
            Stdio.printf("  reparented=%d\n", ux_ak_reparent_count());
            Stdio.printf("demo up\n");
            }
        return (i32)0;
        }
    }

void main(void)
    {
    bool headless = getenv((u8*)"UX_GL_HEADLESS") != (u8*)0;
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(!headless);
    Controller* c = new Controller();
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    app.setDelegate(c);
    if (!headless) { uxAutoQuit(); }
    app.run();
    if (gFails == 0)
        {
        Stdio.printf("PASS: AppKit scroll panel -- a native control spawned into the scroll's document view\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
