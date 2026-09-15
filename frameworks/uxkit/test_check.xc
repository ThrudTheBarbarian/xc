// test_check.xc — a checkbox on the GEM backend.
//
// UXCheckbox is CUSTOM-DRAWN (kind View -> a G_USERDEF here), because GEM has no native checkbox
// object.  The SAME class runs on Win32 (test_win32_check.xc).  This proves it on GEM: two clicks
// through the real responder chain (dispatchMouse -> objc_find -> the control -> mouseDown) toggle
// it on then off, each firing target/action.
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXBoot.xc"

class Controller : Object<UXApplicationDelegate>
    {
    UXCheckbox* box;
    i32 toggles;
    void init(void)
        {
        toggles = (i32)0;
        }

    void onToggle(UXControl* c)
        {
        toggles = toggles + (i32)1;
        Stdio.printf("  toggle %d: checked=%d\n", toggles, box.isChecked() ? (i32)1 : (i32)0);
        }

    void clickCentre(UXWindow* win, UXView* v)
        {
        UXRect r = v.absoluteFrame();
        UXEvent* e = new UXEvent();
        e.kind = (u8)UXEventMouseDown;
        e.x = (i16)(r.x + r.w / (i16)2);
        e.y = (i16)(r.y + r.h / (i16)2);
        win.dispatchMouse(e);
        }

    i32 applicationDidStart(UXApplication* a)
        {
        UXView* content = new UXView();
        UXWindow* win = new UXWindow();
        a.addWindow(win);
        win.open("check", UXGeom.make((i16)4, (i16)4, (i16)180, (i16)80), content);

        box = new UXCheckbox();
        box.setTitle("Enable");
        box.setAction(&self.onToggle);
        content.addSubview(box, UXGeom.make((i16)8, (i16)8, (i16)120, (i16)16));
        win.tree.finalise();
        win.displayAll();

        Stdio.printf("1. initial: checked=%d (expect 0)\n", box.isChecked() ? (i32)1 : (i32)0);
        self.clickCentre(win, box);
        Stdio.printf("2. after click 1: checked=%d (expect 1)\n", box.isChecked() ? (i32)1 : (i32)0);
        self.clickCentre(win, box);
        Stdio.printf("3. after click 2: checked=%d (expect 0)\n", box.isChecked() ? (i32)1 : (i32)0);

        if (toggles == (i32)2 && !box.isChecked())
            {
            Stdio.printf("PASS: a custom-drawn control toggles through the GEM responder chain.\n");
            }
        else
            {
            Stdio.printf("FAIL: toggles=%d checked=%d\n", toggles, box.isChecked() ? (i32)1 : (i32)0);
            }
        a.stop();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }
    gDriver = new UXGemDriver();
    UXApplication* app = new UXApplication();
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run();
    }
