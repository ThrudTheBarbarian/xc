// demo_appkit_scroll.xc — native scrolling: the neutral toolkit inside a real NSScrollView.
//
// A document far taller than the window; the app reports its content size and NSScrollView provides
// native scrolling (scrollbar, wheel, trackpad, elastic overscroll) with no scroll code in the app.
// The toolkit does not shift the tree (windowScrollY is 0 on AppKit) — NSScrollView owns the offset.
//
//   Build+run:  make appkit-scroll  (macOS; scroll with the trackpad/wheel/scrollbar)
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"
#import "demo_autoquit.xc" // UX_AUTOQUIT: let a sweep run this unattended

#define ROWS 50
#define ROW_H 30
#define DOC_W 320

// A tall document that paints ROWS banded rows with a moving marker, so scrolling is obvious.
class Doc : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.drawText((u8*)"top — scroll down (trackpad / wheel / scrollbar)", (i16)10, (i16)8, (i32)1, (i32)0);
        for (i32 i = (i32)0; i < (i32)ROWS; i = i + (i32)1)
            {
            i32 y = i * (i32)ROW_H + (i32)22;
            if ((i & (i32)1) == (i32)0)
                {
                g.fillRect(UXGeom.make((i16)8, (i16)y, (i16)(DOC_W - 16), (i16)(ROW_H - 4)), (i32)8); // grey band
                }
            i32 mx = (i32)12 + (i * (i32)6); // a marker that walks right
            while (mx > (i32)(DOC_W - 24))
                {
                mx = mx - (i32)(DOC_W - 36);
                }
            g.fillRect(UXGeom.make((i16)mx, (i16)(y + (i32)4), (i16)16, (i16)16), (i32)2); // red marker
            }
        g.drawText((u8*)"bottom — you reached the end", (i16)10, (i16)((i32)ROWS * (i32)ROW_H + (i32)26), (i32)1, (i32)0);
        }
    }

    class Ctl : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    i32 applicationDidStart(UXApplication* a)
        {
        Doc* doc = new Doc();
        win = new UXWindow();
        win.open((u8*)"UXKit — native scrolling", UXGeom.make((i16)160, (i16)160, (i16)DOC_W, (i16)320), doc);
        a.addWindow(win);
        win.setContentSize((i16)DOC_W, (i16)((i32)ROWS * (i32)ROW_H + (i32)60)); // taller than the window
        win.displayAll();
        Stdio.printf("scroll demo up — content is taller than the window; scroll it\n");
        return (i32)0;
        }
    } void main(void)
    {
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true);
    Ctl* c = new Ctl();
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    app.setDelegate(c);
    uxAutoQuit();
    app.run();
    }
