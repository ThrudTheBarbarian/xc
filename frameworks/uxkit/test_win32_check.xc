// test_win32_check.xc — a checkbox on the Win32 backend.
//
// UXCheckbox is a CUSTOM-DRAWN neutral control (no native checkbox on GEM or a bare Win32
// window), so the same class paints and toggles identically on every backend.  This drives it
// through the real run loop: two posted clicks toggle it on then off, each firing target/action.
//
//   Build+run:  sh run_win32_check.sh   (xtc -A win64 -> .exe, run under Wine; needs wine)
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
    UXCheckbox* box;
    void setDriver(UXWin32Driver* d)
        {
        drv = d;
        }

    void onToggle(UXControl* c)
        {
        UXCheckbox* cb = (UXCheckbox* ?)c;
        Stdio.printf("toggle: checked=%d\n", cb != (UXCheckbox*)0 && cb.isChecked() ? (i32)1 : (i32)0);
        }

    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* win = new UXWindow();
        UXView* content = new UXView();
        box = new UXCheckbox();
        box.setTitle((u8*)"Enable");
        box.setAction(&self.onToggle);

        win.open((u8*)"Check", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)90), content);
        content.addSubview(box, UXGeom.make((i16)10, (i16)10, (i16)120, (i16)16));
        app.addWindow(win);

        pointer hwnd = drv.windowNative(win.handle);
        u32 lp = ((u32)16 << (u32)16) | (u32)14;                          // inside the checkbox
        PostMessageA(hwnd, (u32)WM_LBUTTONDOWN, (pointer)0, (pointer)lp); // -> checked
        PostMessageA(hwnd, (u32)WM_LBUTTONDOWN, (pointer)0, (pointer)lp); // -> unchecked
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
    Stdio.printf("final=%d\n", c.box.isChecked() ? (i32)1 : (i32)0);
    if (!c.box.isChecked())
        {
        Stdio.printf("PASS: click toggles a custom-drawn control\n");
        }
    else
        {
        Stdio.printf("FAIL\n");
        }
    }
