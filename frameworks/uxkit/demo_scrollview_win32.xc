// demo_scrollview_win32.xc — the standalone UXScrollView on AppKit: a tall column of custom-drawn cards
// in a short viewport, mapped to a native NSScrollView.  Same content as demo_scrollview (GEM).
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXScrollView.xc"
#import "UXString.xc"

#define SV_CARDS 20
#define SV_CARDH 34

class Card : UXView
    {
    i32 n;
    void init(void)
        {
        super.init();
        n = (i32)0;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRect(UXGeom.make((i16)2, (i16)2, (i16)(b.w - (i16)4), (i16)(b.h - (i16)4)),
                   (n & (i32)1) == (i32)0 ? (i32)0 : (i32)8);
        u8* label = UXStr.append((u8*)"card ", UXStr.fromInt(n));
        g.drawText(label, (i16)10, (i16)((b.h - (i16)16) / (i16)2), (i32)1, (i32)16);
        }
    } class SvCanvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)0, (i16)0, dirty.w, dirty.h), (i32)8);
        }
    }

    class SvKit : Object<UXApplicationDelegate>
    {
    UXApplication* app;
    UXWindow* win;
    UXScrollView* scroll;

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        SvCanvas* canvas = new SvCanvas();
        win = new UXWindow();
        win.open((u8*)"Scroll View", UXGeom.make((i16)90, (i16)70, (i16)240, (i16)220), canvas);
        a.addWindow(win);

        scroll = new UXScrollView();
        canvas.addSubview(scroll, UXGeom.make((i16)10, (i16)10, (i16)220, (i16)200));
        scroll.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        scroll.setLineHeight((i16)SV_CARDH);

        UXView* doc = scroll.document();
        for (i32 i = (i32)0; i < (i32)SV_CARDS; i = i + (i32)1)
            {
            Card* c = new Card();
            c.n = i;
            doc.addSubview(c, UXGeom.make((i16)0, (i16)(i * (i32)SV_CARDH), (i16)218, (i16)SV_CARDH));
            }
        scroll.setDocumentHeight((i32)SV_CARDS * (i32)SV_CARDH);

        win.tree.finalise();
        win.displayAll();
        Stdio.printf("demo_scrollview_win32 up\n");
        return (i32)0;
        }
    }

    void
    main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    SvKit* kit = new SvKit();
    UXApplication* app = new UXApplication();
    app.setDelegate(kit);
    app.run();
    }
