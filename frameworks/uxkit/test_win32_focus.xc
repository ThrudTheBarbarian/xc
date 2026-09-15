// test_win32_focus.xc — keyboard focus traversal + the default button, on Win32.
//
// This exercises the NEUTRAL tab-ring (UXWindow.moveFocus) and the app-declared default button
// (§5) on the second backend, with no Win32-specific focus code: a field that doesn't consume a
// key lets it climb the responder chain to the window, which turns Tab into focus movement and
// Return into firing the default button.  Tab and Return arrive as ordinary WM_CHARs (0x09 /
// 0x0D), so the driver needs nothing beyond the WM_CHAR decode the text-field demo already uses.
//
//   Build+run:  sh run_win32_focus.sh   (xtc -A win64 -> .exe, run under Wine; needs wine)
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWin32.h.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

class Controller : Object<UXApplicationDelegate>
    {
    UXWin32Driver* drv;
    UXTextField* f1;
    UXTextField* f2;
    i32 fired;
    void setDriver(UXWin32Driver* d)
        {
        drv = d;
        }
    void onOK(UXControl* c)
        {
        fired = (i32)1;
        Stdio.printf("default-button fired\n");
        }

    void key(pointer hwnd, i32 ch)
        {
        PostMessageA(hwnd, (u32)WM_CHAR, (pointer)ch, (pointer)0);
        }

    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* win = new UXWindow();
        UXView* content = new UXView();
        f1 = new UXTextField();
        f2 = new UXTextField();
        UXButton* ok = new UXButton();
        ok.setTitle((u8*)"OK");
        ok.setAction(&self.onOK);

        win.open((u8*)"Focus", UXGeom.make((i16)60, (i16)60, (i16)240, (i16)120), content);
        content.addSubview(f1, UXGeom.make((i16)10, (i16)10, (i16)120, (i16)20));
        content.addSubview(f2, UXGeom.make((i16)10, (i16)40, (i16)120, (i16)20));
        content.addSubview(ok, UXGeom.make((i16)10, (i16)70, (i16)56, (i16)18));
        win.setDefaultButton(ok); // Return fires THIS, wherever focus is (§5)
        app.addWindow(win);

        // Click field 1, type 'A'; Tab to field 2, type 'B'; Return fires the default button.
        // All through the real queue and the neutral responder chain.
        pointer hwnd = drv.windowNative(win.handle);
        u32 lp = ((u32)18 << (u32)16) | (u32)18; // inside field 1 (y=18)
        PostMessageA(hwnd, (u32)WM_LBUTTONDOWN, (pointer)0, (pointer)lp);
        self.key(hwnd, (i32)65); // 'A' -> field 1
        self.key(hwnd, (i32)9);  // Tab -> focus field 2
        self.key(hwnd, (i32)66); // 'B' -> field 2
        self.key(hwnd, (i32)13); // Return -> default button
        PostQuitMessage((i32)0);
        return (i32)0;
        }
    }

    void
    main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    Controller* c = new Controller();
    c.setDriver(d);
    UXApplication* app = new UXApplication();
    app.setDelegate(c);
    app.run();
    Stdio.printf("f1=%s f2=%s fired=%d\n", c.f1.text(), c.f2.text(), c.fired);
    if (c.f1.text()[0] == (u8)65 && c.f1.text()[1] == (u8)0 &&
        c.f2.text()[0] == (u8)66 && c.f2.text()[1] == (u8)0 && c.fired == (i32)1)
        {
        Stdio.printf("PASS: Tab moved focus, Return fired the default button\n");
        }
    else
        {
        Stdio.printf("FAIL\n");
        }
    }
