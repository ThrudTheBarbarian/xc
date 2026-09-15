// test_win32_winroute.xc — a click on the SECOND window must route to the second window's view, not
// the first (the old windowAtPoint stub sent every click to window 1).  Two windows, each a self-drawn
// view; post a click to window 2 and check which view's mouseDown fired.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWin32.h.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

class ClickView : UXView
    {
    i32 tag;
    bool clicked;
    void init(void)
        {
        super.init();
        tag = (i32)0;
        clicked = false;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }
    void mouseDown(UXEvent* e)
        {
        clicked = true;
        }
    }

    class C : Object<UXApplicationDelegate>
    {
    UXWin32Driver* drv;
    ClickView* v1;
    ClickView* v2;
    void setDriver(UXWin32Driver* d)
        {
        drv = d;
        }
    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* w1 = new UXWindow();
        UXView* c1 = new UXView();
        w1.open((u8*)"One", UXGeom.make((i16)20, (i16)20, (i16)200, (i16)150), c1);
        app.addWindow(w1);
        v1 = new ClickView();
        v1.tag = (i32)1;
        c1.addSubview(v1, UXGeom.make((i16)0, (i16)0, (i16)200, (i16)150));
        w1.tree.finalise();
        w1.displayAll();

        UXWindow* w2 = new UXWindow();
        UXView* c2 = new UXView();
        w2.open((u8*)"Two", UXGeom.make((i16)260, (i16)20, (i16)200, (i16)150), c2);
        app.addWindow(w2);
        v2 = new ClickView();
        v2.tag = (i32)2;
        c2.addSubview(v2, UXGeom.make((i16)0, (i16)0, (i16)200, (i16)150));
        w2.tree.finalise();
        w2.displayAll();

        pointer h2 = drv.windowNative(w2.handle);
        u32 lp = ((u32)50 << (u32)16) | (u32)50; // client (50,50) inside window 2
        PostMessageA(h2, (u32)WM_LBUTTONDOWN, (pointer)0, (pointer)lp);
        PostQuitMessage((i32)0);
        return (i32)0;
        }
    } void main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    C* c = new C();
    c.setDriver(d);
    UXApplication* app = new UXApplication();
    app.setDelegate(c);
    app.run();
    Stdio.printf("v1.clicked=%d v2.clicked=%d\n", c.v1.clicked ? (i32)1 : (i32)0, c.v2.clicked ? (i32)1 : (i32)0);
    if (!c.v1.clicked && c.v2.clicked)
        {
        Stdio.printf("PASS: click routed to the window it landed on\n");
        }
    else
        {
        Stdio.printf("FAIL: routed to the wrong window\n");
        }
    }
