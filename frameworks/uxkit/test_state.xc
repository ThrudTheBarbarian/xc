// test_state.xc — enabled/hidden controls on GEM.
//
// The GEM complement to test_win32_enabled/hidden: the neutral rules (a disabled control drops a
// hit; a hidden one is not drawn or hit) run on GEM too — the driver maps them to OS_DISABLED and
// OF_HIDETREE, and UXControl.mouseDown / objc_find honour them.  A button, no field, so it sidesteps
// COMPILER-THREAD #7.  Click its centre through each state and count the fires.
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXBoot.xc"

class C : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    UXButton* btn;
    i32 fired;
    void onClick(UXControl* c)
        {
        fired = fired + (i32)1;
        }
    void clickBtn(void)
        {
        UXRect r = btn.absoluteFrame();
        UXEvent* e = new UXEvent();
        e.kind = (u8)UXEventMouseDown;
        e.x = (i16)(r.x + r.w / (i16)2);
        e.y = (i16)(r.y + r.h / (i16)2);
        win.dispatchMouse(e);
        }
    i32 applicationDidStart(UXApplication* a)
        {
        UXView* content = new UXView();
        win = new UXWindow();
        a.addWindow(win);
        btn = new UXButton();
        btn.setTitle("Go");
        btn.setAction(&self.onClick);
        win.open("state", UXGeom.make((i16)4, (i16)4, (i16)180, (i16)70), content);
        content.addSubview(btn, UXGeom.make((i16)10, (i16)10, (i16)60, (i16)20));
        win.tree.finalise();
        win.displayAll();

        self.clickBtn(); // enabled -> 1
        btn.setEnabled(false);
        self.clickBtn(); // disabled -> still 1
        btn.setEnabled(true);
        self.clickBtn(); // enabled -> 2
        btn.setHidden(true);
        self.clickBtn(); // hidden  -> still 2
        btn.setHidden(false);
        self.clickBtn(); // shown   -> 3
        Stdio.printf("fired=%d (expect 3)\n", fired);
        Stdio.printf(fired == (i32)3 ? "PASS: disabled and hidden controls drop a real hit on GEM\n" : "FAIL\n");
        a.stop();
        return (i32)0;
        }
    } void main(void)
    {
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }
    gDriver = new UXGemDriver();
    UXApplication* app = new UXApplication();
    app.setDelegate(new C());
    app.run();
    }
