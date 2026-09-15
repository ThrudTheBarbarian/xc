// test_win32_loop.xc — the neutral RUN LOOP on Win32.
//
// test_win32_real.xc proved the neutral view layer paints and hit-tests on the Win32 backend,
// but it drove the clicks by hand.  This proves the whole thing runs under UXApplication.run()
// — the SAME loop the GEM app uses — pumping the REAL Win32 message queue: a posted
// WM_LBUTTONDOWN travels driver.nextEvent (GetMessage -> decode) -> UXApplication.dispatchEvent
// -> the window -> UXView.mouseDown, and a posted WM_QUIT ends the loop.  Nothing in the app is
// Win32-aware except selecting the backend and the one line that simulates the OS delivering a
// click (a real program's clicks come from the user, not a PostMessage).
//
//   Build+run:  sh run_win32_loop.sh   (xtc -A win64 -> .exe, run under Wine; needs wine)
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWin32.h.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

class Canvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)10, (i16)10, (i16)50, (i16)30), (i32)8);
        Stdio.printf("fill=10,10,50,30\n");
        }
    bool acceptsFirstResponder(void)
        {
        return true;
        }
    void mouseDown(UXEvent* e)
        {
        Stdio.printf("loop-mouseDown=%d,%d\n", (i32)e.x, (i32)e.y);
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
        Stdio.printf("start\n");
        UXWindow* win = new UXWindow();
        Canvas* canvas = new Canvas();
        win.open((u8*)"UXKit", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)120), canvas);
        app.addWindow(win); // so dispatchEvent can find it by handle

        // Simulate the OS delivering a click, then ask the loop to quit.  Both go through the
        // real Win32 queue; the neutral loop pumps them via nextEvent — we do NOT call
        // dispatchMouse ourselves.  lParam packs (y<<16)|x = (40<<16)|30.
        pointer hwnd = drv.windowNative(win.handle);
        u32 lp = ((u32)40 << (u32)16) | (u32)30;
        PostMessageA(hwnd, (u32)WM_LBUTTONDOWN, (pointer)0, (pointer)lp);
        PostQuitMessage((i32)0); // GetMessage returns 0 after the click drains
        return (i32)0;           // 0 = keep running; the loop takes over
        }
    }

    void
    main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d; // select the backend
    Delegate* del = new Delegate();
    del.setDriver(d);
    UXApplication* app = new UXApplication();
    app.setDelegate(del);
    i32 rc = app.run(); // boot -> applicationDidStart -> the pump loop
    Stdio.printf("stopped rc=%d\n", rc);
    }
