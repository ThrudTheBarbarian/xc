// test_radio.xc — radio buttons (mutual exclusion) on the GEM backend.
//
// UXRadioButton is custom-drawn (kind View -> G_USERDEF); UXRadioGroup's select() is the whole
// of "radio behaviour", pure neutral logic.  The same classes run on Win32 (test_win32_radio.xc).
// Two clicks through the GEM responder chain select radio 0 then radio 2; exactly one stays on.
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXBoot.xc"

class Controller : Object<UXApplicationDelegate>
    {
    UXRadioGroup* grp;
    UXRadioButton* r0;
    UXRadioButton* r2;

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
        win.open("radio", UXGeom.make((i16)4, (i16)4, (i16)180, (i16)150), content);

        grp = new UXRadioGroup();
        r0 = new UXRadioButton();
        r0.setTitle("A");
        UXRadioButton* r1 = new UXRadioButton();
        r1.setTitle("B");
        r2 = new UXRadioButton();
        r2.setTitle("C");
        content.addSubview(r0, UXGeom.make((i16)8, (i16)6, (i16)120, (i16)16));
        content.addSubview(r1, UXGeom.make((i16)8, (i16)26, (i16)120, (i16)16));
        content.addSubview(r2, UXGeom.make((i16)8, (i16)46, (i16)120, (i16)16));
        grp.add(r0);
        grp.add(r1);
        grp.add(r2);
        win.tree.finalise();
        win.displayAll();

        self.clickCentre(win, r0);
        Stdio.printf("1. clicked A: r0=%d r2=%d (expect 1 0)\n",
                     r0.isSelected() ? (i32)1 : (i32)0, r2.isSelected() ? (i32)1 : (i32)0);
        self.clickCentre(win, r2);
        Stdio.printf("2. clicked C: r0=%d r2=%d (expect 0 1)\n",
                     r0.isSelected() ? (i32)1 : (i32)0, r2.isSelected() ? (i32)1 : (i32)0);

        UXRadioButton* sel = grp.selected();
        if (!r0.isSelected() && r2.isSelected() && sel == r2)
            {
            Stdio.printf("PASS: the group keeps exactly one selected on GEM.\n");
            }
        else
            {
            Stdio.printf("FAIL\n");
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
