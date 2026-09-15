// test_win32_multiwindow.xc — closing a SECONDARY window must NOT quit the whole app on Win32.
//
// Regression: the driver used to PostQuitMessage on every window's WM_DESTROY, so closing any secondary
// window (e.g. the colour picker via its Select button) posted WM_QUIT and terminated the program.  The
// app owns the quit decision (UXApplication.closeWindow quits only when the last window goes); the driver
// posts WM_QUIT only when no windows remain.  Headless-deterministic; skips cleanly when wine is absent.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXWin32.h.xc"
#define BM_CLICK 245

class Closer : Object
    {
    weak : UXApplication* app;
    weak : UXWindow* w;
    void init(void)
        {
        app = (UXApplication*)0;
        w = (UXWindow*)0;
        }
    // as a real button action would
    void onClose(UXControl* c)
        {
        app.closeWindowLater(w);
        }
    }

    // Drain queued messages (as the run loop does); report whether WM_QUIT appeared.
    i32 sawQuit(UXApplication* app)
    {
    app.drainPendingCloses();
    i32 q = (i32)0;
    MSG msg;
    while (PeekMessageA((pointer)&msg, (pointer)0, (u32)0, (u32)0, (u32)PM_REMOVE) != (i32)0)
        {
        if (msg.message == (u32)WM_QUIT)
            {
            q = (i32)1;
            continue;
            }
        TranslateMessage((pointer)&msg);
        DispatchMessageA((pointer)&msg);
        app.drainPendingCloses();
        }
    return q;
    }

void main(void)
    {
    gDriver = new UXWin32Driver();
    UXApplication* app = new UXApplication();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("boot failed\n");
        return;
        }
    gApp = app;

    UXWindow* mainw = new UXWindow();
    UXView* mc = new UXView();
    mainw.open((u8*)"Main", UXGeom.make((i16)60, (i16)60, (i16)200, (i16)120), mc);
    mainw.displayAll();
    app.addWindow(mainw);

    UXWindow* sec = new UXWindow();
    UXView* sc = new UXView();
    sec.open((u8*)"Second", UXGeom.make((i16)300, (i16)60, (i16)200, (i16)120), sc);
    Closer* cl = new Closer();
    cl.app = app;
    cl.w = sec;
    UXButton* b = new UXButton();
    b.setTitle((u8*)"Close");
    b.setAction(&cl.onClose);
    sc.addSubview(b, UXGeom.make((i16)8, (i16)70, (i16)80, (i16)24));
    sec.displayAll();
    app.addWindow(sec);

    // Click Close on the SECONDARY window — the app must survive (main still open).
    pointer parent = gW32Hwnds[sec.handle];
    pointer btn = (pointer)0;
    for (i32 i = (i32)0; i < (i32)16; i = i + (i32)1)
        {
        pointer h = GetDlgItem(parent, (i32)1000 + i);
        if (h != (pointer)0 && GetWindowLongPtrA(h, (i32)GWLP_USERDATA) == (pointer)b)
            {
            btn = h;
            break;
            }
        }
    SendMessageA(btn, (u32)BM_CLICK, (pointer)0, (pointer)0);
    Stdio.printf("secondary-close quit=%d\n", sawQuit(app)); // want 0 — app survives
    Stdio.printf("secondary-open=%d main-open=%d\n", sec.isOpen() ? (i32)1 : (i32)0, mainw.isOpen() ? (i32)1 : (i32)0);

    // Close the LAST window — THIS must post WM_QUIT so the app can exit.
    app.closeWindow(mainw);
    Stdio.printf("last-close quit=%d\n", sawQuit(app)); // want 1 — app exits
    Stdio.printf("done\n");
    }
