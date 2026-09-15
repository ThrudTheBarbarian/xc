// test_controls.xc — the custom-drawn controls composing on GEM.
//
// A form of label + checkbox + radio group + button, driven through the GEM responder chain.
// It deliberately omits an editable field so it sidesteps COMPILER-THREAD #7 (field + G_USERDEF
// crashes libGEM's objc_edit); what it proves is that the SESSION's new controls compose and
// drive on GEM, the same way test_win32_kitchensink.xc proves the fuller form on Win32.
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXBoot.xc"

class Panel : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    UXCheckbox* agree;
    UXRadioGroup* plan;
    UXRadioButton* basic;
    UXRadioButton* pro;
    i32 applied;

    void onApply(UXControl* c)
        {
        applied = applied + (i32)1;
        u8* p = plan.selected() == pro ? (u8*)"pro" : (plan.selected() == basic ? (u8*)"basic" : (u8*)"none");
        Stdio.printf("apply: agree=%d plan=%s\n", agree.isChecked() ? (i32)1 : (i32)0, p);
        }
    void clickCentre(UXView* v)
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
        UXLabel* title = new UXLabel();
        title.setText("Choose a plan:");
        agree = new UXCheckbox();
        agree.setTitle("I agree");
        plan = new UXRadioGroup();
        basic = new UXRadioButton();
        basic.setTitle("Basic");
        pro = new UXRadioButton();
        pro.setTitle("Pro");
        UXButton* apply = new UXButton();
        apply.setTitle("Apply");
        apply.setAction(&self.onApply);

        win = new UXWindow();
        a.addWindow(win);
        win.open("Plan", UXGeom.make((i16)4, (i16)4, (i16)220, (i16)170), content);
        content.addSubview(title, UXGeom.make((i16)10, (i16)8, (i16)120, (i16)16));
        content.addSubview(agree, UXGeom.make((i16)10, (i16)32, (i16)120, (i16)16));
        content.addSubview(basic, UXGeom.make((i16)10, (i16)56, (i16)90, (i16)16));
        content.addSubview(pro, UXGeom.make((i16)10, (i16)76, (i16)90, (i16)16));
        content.addSubview(apply, UXGeom.make((i16)10, (i16)104, (i16)64, (i16)20));
        plan.add(basic);
        plan.add(pro);
        win.tree.finalise();
        win.displayAll();

        self.clickCentre(agree); // tick
        self.clickCentre(pro);   // choose Pro
        self.clickCentre(apply); // apply -> onApply reads state

        bool ok = applied == (i32)1 && agree.isChecked() && plan.selected() == pro && !basic.isSelected();
        Stdio.printf(ok ? "PASS: label + checkbox + radio group + button compose on GEM\n" : "FAIL\n");
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
    app.setDelegate(new Panel());
    app.run();
    }
