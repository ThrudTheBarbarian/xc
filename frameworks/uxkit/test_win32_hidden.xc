// test_win32_hidden.xc — hidden controls on Win32.
//
// A hidden view is not drawn AND not hit: the driver's paint walk and hit test both skip a node
// whose hidden flag is set (structSetHidden/IsHidden — the neutral setHidden rides on it).  Click
// the button's centre three times: visible (fires), hidden (a click into the same spot is ignored),
// visible again (fires).  The count goes 1 -> 1 -> 2.
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
        gWin.open((u8*)"Hide", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)90), content);
        content.addSubview(gBtn, UXGeom.make((i16)10, (i16)10, (i16)60, (i16)20));
        app.addWindow(gWin);

        clickBtn();
        Stdio.printf("visible click -> fired=%d\n", gFired); // 1
        gBtn.setHidden(true);
        clickBtn();
        Stdio.printf("hidden  click -> fired=%d\n", gFired); // still 1
        gBtn.setHidden(false);
        clickBtn();
        Stdio.printf("shown   click -> fired=%d\n", gFired); // 2

        Stdio.printf(gFired == (i32)2 ? "PASS: a hidden control is not hit\n" : "FAIL\n");
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
