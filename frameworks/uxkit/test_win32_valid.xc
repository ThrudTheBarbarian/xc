// test_win32_valid.xc — per-character field validation on Win32.
//
// A field with validation "99999" accepts only digits.  Typing "1a2b3" through the real message
// pump yields "123" — the letters are rejected keystroke-by-keystroke by the driver's edit
// engine, the same alphabet GEM's objc_edit enforces.
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
    UXTextField* field;
    void setDriver(UXWin32Driver* d)
        {
        drv = d;
        }
    void key(pointer h, i32 ch)
        {
        PostMessageA(h, (u32)WM_CHAR, (pointer)ch, (pointer)0);
        }

    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* win = new UXWindow();
        UXView* content = new UXView();
        field = new UXTextField();
        win.open((u8*)"Valid", UXGeom.make((i16)80, (i16)80, (i16)220, (i16)80), content);
        content.addSubview(field, UXGeom.make((i16)10, (i16)10, (i16)160, (i16)20));
        field.setValidation((u8*)"99999"); // digits only
        app.addWindow(win);

        pointer hwnd = drv.windowNative(win.handle);
        u32 lp = ((u32)18 << (u32)16) | (u32)18;
        PostMessageA(hwnd, (u32)WM_LBUTTONDOWN, (pointer)0, (pointer)lp);
        self.key(hwnd, (i32)49); // '1'
        self.key(hwnd, (i32)97); // 'a'  (rejected)
        self.key(hwnd, (i32)50); // '2'
        self.key(hwnd, (i32)98); // 'b'  (rejected)
        self.key(hwnd, (i32)51); // '3'
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
    u8* t = c.field.text();
    Stdio.printf("field=%s\n", t);
    if (t[0] == (u8)49 && t[1] == (u8)50 && t[2] == (u8)51 && t[3] == (u8)0)
        {
        Stdio.printf("PASS: only digits accepted (letters rejected per-keystroke)\n");
        }
    else
        {
        Stdio.printf("FAIL\n");
        }
    }
