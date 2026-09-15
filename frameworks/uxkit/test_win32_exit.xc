// test_win32_exit.xc — the kitchen sink must EXIT when its last window closes.
//
// `make win32` hangs on exit under Wine: the window works throughout, the close box takes it away,
// and the process never returns — it needs force-quitting.  This drives the REAL run loop with the
// REAL delegate, then posts the close box's own message at the main window.  run() returning is the
// whole assertion; if this times out, the hang is reproduced headlessly and can be bisected.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "ks_app.xc"

// The kitchen sink, plus "and then close the window" — so the close happens inside the real loop.
class ExitProbe : Object<UXApplicationDelegate>
    {
    KitchenSink* ks;
    UXWin32Driver* drv;
    void init(void)
        {
        ks = (KitchenSink*)0;
        drv = (UXWin32Driver*)0;
        }
    i32 applicationDidStart(UXApplication* a)
        {
        i32 rc = ks.applicationDidStart(a);
        if (rc != (i32)0)
            {
            return rc;
            }
        // ONE window only: closing the main window while others are open is deliberately not a quit,
        // so opening the rest would make this test hang on correct behaviour.
        Stdio.printf("up: one window\n");
        // THE CLOSE BOX, as the window manager delivers it: WM_SYSCOMMAND/SC_CLOSE, not WM_CLOSE.
        // That distinction is the whole bug — letting DefWindowProc have SC_CLOSE makes it SEND
        // WM_CLOSE, and a sent message never enters the queue that nextEvent reads, so the window was
        // destroyed behind the toolkit's back and the loop waited for ever on a window that was gone.
        // Posting WM_CLOSE here instead would test nothing: that is the path that always worked.
        PostMessageA(drv.windowNative(ks.win.handle), (u32)WM_SYSCOMMAND, (pointer)SC_CLOSE, (pointer)0);
        return (i32)0;
        }
    }

    void
    main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    ExitProbe* probe = new ExitProbe();
    probe.ks = new KitchenSink();
    probe.drv = d;
    UXApplication* app = new UXApplication();
    app.setDelegate(probe);
    Stdio.printf("entering run()\n");
    i32 rc = app.run();
    Stdio.printf("run() returned %d\n", rc);
    Stdio.printf("PASS: the app exits when its last window closes\n");
    }
