// test_win32_radio.xc — radio buttons (mutual exclusion) on the Win32 backend.
//
// UXRadioButton is a custom-drawn neutral control; the exclusion is pure UXRadioGroup logic.
// Same class, same behaviour on GEM (test_radio.xc) and here.  Two posted clicks select radio 0
// then radio 2; the group leaves exactly one selected.
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
    UXRadioGroup* grp;
    UXRadioButton* r0;
    UXRadioButton* r2;
    void setDriver(UXWin32Driver* d)
        {
        drv = d;
        }

    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* win = new UXWindow();
        UXView* content = new UXView();
        grp = new UXRadioGroup();
        r0 = new UXRadioButton();
        r0.setTitle((u8*)"A");
        UXRadioButton* r1 = new UXRadioButton();
        r1.setTitle((u8*)"B");
        r2 = new UXRadioButton();
        r2.setTitle((u8*)"C");

        win.open((u8*)"Radio", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)120), content);
        content.addSubview(r0, UXGeom.make((i16)10, (i16)10, (i16)120, (i16)16));
        content.addSubview(r1, UXGeom.make((i16)10, (i16)30, (i16)120, (i16)16));
        content.addSubview(r2, UXGeom.make((i16)10, (i16)50, (i16)120, (i16)16));
        grp.add(r0);
        grp.add(r1);
        grp.add(r2);
        app.addWindow(win);

        pointer hwnd = drv.windowNative(win.handle);
        u32 lp0 = ((u32)18 << (u32)16) | (u32)16; // radio 0 (y=18)
        u32 lp2 = ((u32)58 << (u32)16) | (u32)16; // radio 2 (y=58)
        PostMessageA(hwnd, (u32)WM_LBUTTONDOWN, (pointer)0, (pointer)lp0);
        PostMessageA(hwnd, (u32)WM_LBUTTONDOWN, (pointer)0, (pointer)lp2);
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
    Stdio.printf("r0=%d r2=%d\n", c.r0.isSelected() ? (i32)1 : (i32)0, c.r2.isSelected() ? (i32)1 : (i32)0);
    UXRadioButton* sel = c.grp.selected();
    if (!c.r0.isSelected() && c.r2.isSelected() && sel == c.r2)
        {
        Stdio.printf("PASS: the group keeps exactly one selected\n");
        }
    else
        {
        Stdio.printf("FAIL\n");
        }
    }
