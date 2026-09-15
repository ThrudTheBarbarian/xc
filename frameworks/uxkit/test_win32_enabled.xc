// test_win32_enabled.xc — enabled/disabled controls on Win32.
//
// A disabled control does not fire even when clicked squarely — UXControl.mouseDown checks
// isEnabled, the same neutral rule on every backend, riding on the driver's shadow-tree enabled
// state.  Click the button's CENTRE three times: enabled (fires), disabled (a real hit, ignored),
// enabled again (fires).  The count goes 1 -> 1 -> 2, so the disabled hit was dropped.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

UXWindow* gWin;
UXButton* gBtn;
i32 gFired;

void clickBtn(void)
    {
    UXRect r = gBtn.absoluteFrame();
    UXEvent* e = new UXEvent();
    e.kind = (u8)UXEventMouseDown;
    e.x = (i16)(r.x + r.w / (i16)2);
    e.y = (i16)(r.y + r.h / (i16)2);
    gWin.dispatchMouse(e);
    }

class Controller : Object<UXApplicationDelegate>
    {
    void onClick(UXControl* c)
        {
        gFired = gFired + (i32)1;
        }

    i32 applicationDidStart(UXApplication* app)
        {
        gWin = new UXWindow();
        UXView* content = new UXView();
        gBtn = new UXButton();
        gBtn.setTitle((u8*)"Go");
        gBtn.setAction(&self.onClick);
        gWin.open((u8*)"En", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)90), content);
        content.addSubview(gBtn, UXGeom.make((i16)10, (i16)10, (i16)60, (i16)20));
        app.addWindow(gWin);

        clickBtn();
        Stdio.printf("enabled  click -> fired=%d\n", gFired); // 1
        gBtn.setEnabled(false);
        clickBtn();
        Stdio.printf("disabled click -> fired=%d\n", gFired); // still 1
        gBtn.setEnabled(true);
        clickBtn();
        Stdio.printf("enabled  click -> fired=%d\n", gFired); // 2

        Stdio.printf(gFired == (i32)2 ? "PASS: a disabled control drops a real hit\n" : "FAIL\n");
        app.stop();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    UXApplication* app = new UXApplication();
    app.setDelegate(new Controller());
    app.run();
    }
