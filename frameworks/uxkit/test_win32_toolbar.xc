// test_win32_toolbar.xc — the native ToolbarWindow32 controls on the Win32 backend.
//
// UXSegmentedControl and UXToolbar both realize as a native ToolbarWindow32 (a check-group and a
// button row).  This drives the value path the way the OS does: a native toolbar button posts a
// WM_COMMAND(MAKEWPARAM(id, BN_CLICKED)) to its parent with lParam = the toolbar HWND.  We fetch each
// toolbar child by its control id (W32_CTRL_ID_BASE + node index) and synthesise those clicks, then
// check the neutral model moved and the action fired.
//
//   Build+run:  sh run_win32_toolbar.sh   (xtc -A win64 -> .exe, run under Wine; needs wine)
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWin32.h.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXSegmentedControl.xc"
#import "UXToolbar.xc"
#import "UXGeometry.xc"

#define BN_CLICKED_ 0

class Controller : Object<UXApplicationDelegate>
    {
    UXWin32Driver* drv;
    UXSegmentedControl* seg;
    UXToolbar* tb;
    i32 segFires;
    i32 tbFires;
    i32 lastTag;

    void setDriver(UXWin32Driver* d)
        {
        drv = d;
        }
    void onSeg(UXControl* c)
        {
        segFires = segFires + (i32)1;
        }
    void onTb(UXControl* c)
        {
        tbFires = tbFires + (i32)1;
        lastTag = tb.itemAt(tb.selection()).tag;
        }

    i32 applicationDidStart(UXApplication* app)
        {
        segFires = (i32)0;
        tbFires = (i32)0;
        lastTag = (i32)0;
        UXWindow* win = new UXWindow();
        UXView* content = new UXView();

        seg = new UXSegmentedControl();
        seg.addSegment((u8*)"Day", (i32)1);
        seg.addSegment((u8*)"Week", (i32)2);
        seg.addSegment((u8*)"Month", (i32)3);
        seg.setAction(&self.onSeg);

        tb = new UXToolbar();
        tb.addItem((u8*)"new", (u8*)"New", (i32)10, (i16)48);
        tb.addSeparator();
        tb.addItem((u8*)"opn", (u8*)"Open", (i32)20, (i16)48);
        tb.setAction(&self.onTb);

        win.open((u8*)"Toolbar", UXGeom.make((i16)80, (i16)80, (i16)360, (i16)140), content);
        content.addSubview(seg, UXGeom.make((i16)8, (i16)8, (i16)220, (i16)26)); // node 1 -> id 1001
        content.addSubview(tb, UXGeom.make((i16)8, (i16)44, (i16)300, (i16)30)); // node 2 -> id 1002
        app.addWindow(win);
        win.displayAll(); // realizes both ToolbarWindow32 children (TB_ADDBUTTONS etc.)

        pointer parent = drv.windowNative(win.handle);
        pointer segHwnd = GetDlgItem(parent, (i32)(1000 + 1));
        pointer tbHwnd = GetDlgItem(parent, (i32)(1000 + 2));
        Stdio.printf("segHwnd=%d tbHwnd=%d\n", segHwnd != (pointer)0 ? (i32)1 : (i32)0,
                     tbHwnd != (pointer)0 ? (i32)1 : (i32)0);

        // Click segment index 2 ("Month"): WM_COMMAND(id=2, BN_CLICKED), lParam=the toolbar HWND.
        if (segHwnd != (pointer)0)
            {
            SendMessageA(parent, (u32)WM_COMMAND, (pointer)(((u32)BN_CLICKED_ << (u32)16) | (u32)2), segHwnd);
            }
        // Click toolbar item tag 20 ("Open").
        if (tbHwnd != (pointer)0)
            {
            SendMessageA(parent, (u32)WM_COMMAND, (pointer)(((u32)BN_CLICKED_ << (u32)16) | (u32)20), tbHwnd);
            }
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

    i32 segSel = c.seg.selectedSegment();
    Stdio.printf("segFires=%d segSel=%d tbFires=%d lastTag=%d\n", c.segFires, segSel, c.tbFires, c.lastTag);
    if (c.segFires == (i32)1 && segSel == (i32)2 && c.tbFires == (i32)1 && c.lastTag == (i32)20)
        {
        Stdio.printf("PASS: native ToolbarWindow32 routes segmented + toolbar clicks\n");
        }
    else
        {
        Stdio.printf("FAIL\n");
        }
    }
