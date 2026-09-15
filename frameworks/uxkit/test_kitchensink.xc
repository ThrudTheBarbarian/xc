// test_kitchensink.xc — the whole form on GEM (field + custom controls together).
//
// The GEM twin of test_win32_kitchensink: menu-less but composing an editable field with
// custom-drawn controls (checkbox, radio group) that once crashed libGEM's objc_edit on field
// focus (COMPILER-THREAD #7, now fixed — Xtg suppresses the AES's internal edit-redraw and paints
// through its own cycle).  Driven through the GEM responder chain.
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXBoot.xc"

class Form : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    UXTextField* name;
    UXCheckbox* subscribe;
    UXRadioGroup* via;
    UXRadioButton* sms;
    i32 submitted;

    void onSubmit(UXControl* c)
        {
        submitted = submitted + (i32)1;
        u8* v = via.selected() == sms ? (u8*)"SMS" : (u8*)"?";
        Stdio.printf("submit: name=%s subscribe=%d via=%s\n",
                     name.text(), subscribe.isChecked() ? (i32)1 : (i32)0, v);
        }
    void click(UXView* vw)
        {
        UXRect r = vw.absoluteFrame();
        UXEvent* e = new UXEvent();
        e.kind = (u8)UXEventMouseDown;
        e.x = (i16)(r.x + r.w / (i16)2);
        e.y = (i16)(r.y + r.h / (i16)2);
        win.dispatchMouse(e);
        }
    void type(u16 k)
        {
        UXEvent* e = new UXEvent();
        e.kind = (u8)UXEventKeyDown;
        e.key = k;
        win.dispatchKey(e);
        }

    i32 applicationDidStart(UXApplication* a)
        {
        UXView* content = new UXView();
        UXLabel* label = new UXLabel();
        label.setText("Name:");
        name = new UXTextField();
        subscribe = new UXCheckbox();
        subscribe.setTitle("Subscribe");
        via = new UXRadioGroup();
        UXRadioButton* email = new UXRadioButton();
        email.setTitle("Email");
        sms = new UXRadioButton();
        sms.setTitle("SMS");
        UXButton* submit = new UXButton();
        submit.setTitle("Submit");
        submit.setAction(&self.onSubmit);

        win = new UXWindow();
        a.addWindow(win);
        win.open("Sign up", UXGeom.make((i16)4, (i16)4, (i16)260, (i16)220), content);
        content.addSubview(label, UXGeom.make((i16)10, (i16)12, (i16)44, (i16)16));
        content.addSubview(name, UXGeom.make((i16)56, (i16)10, (i16)150, (i16)20));
        content.addSubview(subscribe, UXGeom.make((i16)10, (i16)40, (i16)140, (i16)16));
        content.addSubview(email, UXGeom.make((i16)10, (i16)64, (i16)90, (i16)16));
        content.addSubview(sms, UXGeom.make((i16)10, (i16)84, (i16)90, (i16)16));
        content.addSubview(submit, UXGeom.make((i16)10, (i16)110, (i16)64, (i16)20));
        via.add(email);
        via.add(sms);
        win.tree.finalise();
        win.displayAll();

        self.click(name);
        self.type((u16)65);
        self.type((u16)108);   // focus, "Al"
        self.click(subscribe); // tick
        self.click(sms);       // pick SMS
        self.click(submit);    // submit

        u8* n = name.text();
        bool ok = submitted == (i32)1 && n[0] == (u8)65 && n[1] == (u8)108 && n[2] == (u8)0 && subscribe.isChecked() && via.selected() == sms;
        Stdio.printf(ok ? "PASS: a whole form composes and drives on GEM\n" : "FAIL\n");
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
    app.setDelegate(new Form());
    app.run();
    }
