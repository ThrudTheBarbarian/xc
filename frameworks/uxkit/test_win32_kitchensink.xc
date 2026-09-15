// test_win32_kitchensink.xc — a whole form on the Win32 backend.
//
// Everything built this session, composed in one real window and driven end to end through the
// neutral run loop: a menu, a label, a text field, a checkbox, a radio group, and a Submit
// button.  The user types a name, ticks Subscribe, picks SMS, and clicks Submit; the controller
// reads every control's state through the neutral API and prints a summary.  Nothing here is
// Win32-aware except selecting the backend and the lines that simulate the OS delivering input.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWin32.h.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXMenu.xc"
#import "UXGeometry.xc"

class Form : Object<UXApplicationDelegate>
    {
    UXWin32Driver* drv;
    UXTextField* name;
    UXCheckbox* subscribe;
    UXRadioGroup* via;
    UXRadioButton* email;
    UXRadioButton* sms;
    i32 submitted;
    void setDriver(UXWin32Driver* d)
        {
        drv = d;
        }

    void onSubmit(UXControl* c)
        {
        submitted = submitted + (i32)1;
        u8* v = via.selected() == sms ? (u8*)"SMS" : (via.selected() == email ? (u8*)"Email" : (u8*)"none");
        Stdio.printf("submit: name=%s subscribe=%d via=%s\n",
                     name.text(), subscribe.isChecked() ? (i32)1 : (i32)0, v);
        }
    void onQuit(UXMenuItem* m)
        {
        Stdio.printf("menu: Quit\n");
        }

    void click(pointer h, i32 x, i32 y)
        {
        PostMessageA(h, (u32)WM_LBUTTONDOWN, (pointer)0, (pointer)(((u32)y << (u32)16) | (u32)x));
        }
    void key(pointer h, i32 ch)
        {
        PostMessageA(h, (u32)WM_CHAR, (pointer)ch, (pointer)0);
        }

    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* win = new UXWindow();
        UXView* content = new UXView();
        UXLabel* label = new UXLabel();
        label.setText((u8*)"Name:");
        name = new UXTextField();
        subscribe = new UXCheckbox();
        subscribe.setTitle((u8*)"Subscribe");
        via = new UXRadioGroup();
        email = new UXRadioButton();
        email.setTitle((u8*)"Email");
        sms = new UXRadioButton();
        sms.setTitle((u8*)"SMS");
        UXButton* submit = new UXButton();
        submit.setTitle((u8*)"Submit");
        submit.setAction(&self.onSubmit);

        win.open((u8*)"Sign up", UXGeom.make((i16)60, (i16)60, (i16)260, (i16)200), content);
        content.addSubview(label, UXGeom.make((i16)10, (i16)12, (i16)44, (i16)16));
        content.addSubview(name, UXGeom.make((i16)56, (i16)10, (i16)150, (i16)20));
        content.addSubview(subscribe, UXGeom.make((i16)10, (i16)40, (i16)140, (i16)16));
        content.addSubview(email, UXGeom.make((i16)10, (i16)64, (i16)90, (i16)16));
        content.addSubview(sms, UXGeom.make((i16)10, (i16)84, (i16)90, (i16)16));
        content.addSubview(submit, UXGeom.make((i16)10, (i16)110, (i16)64, (i16)20));
        via.add(email);
        via.add(sms);
        app.addWindow(win);

        UXMenuBar* bar = new UXMenuBar();
        UXMenu* file = bar.addMenu((u8*)"File");
        file.addItem((u8*)"Quit", &self.onQuit);
        app.setMenuBar(bar);

        pointer h = drv.windowNative(win.handle);
        self.click(h, (i32)80, (i32)20); // focus the name field
        self.key(h, (i32)65);
        self.key(h, (i32)108);                                    // "Al"
        self.click(h, (i32)16, (i32)48);                          // tick Subscribe
        self.click(h, (i32)16, (i32)92);                          // pick SMS
        self.click(h, (i32)40, (i32)120);                         // Submit -> onSubmit
        PostMessageA(h, (u32)WM_COMMAND, (pointer)1, (pointer)0); // File>Quit = menuId(0,0) = 1
        PostQuitMessage((i32)0);
        return (i32)0;
        }
    }

    void
    main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    Form* f = new Form();
    f.setDriver(d);
    UXApplication* app = new UXApplication();
    app.setDelegate(f);
    app.run();
    u8* n = f.name.text();
    bool ok = f.submitted == (i32)1 && n[0] == (u8)65 && n[1] == (u8)108 && n[2] == (u8)0 && f.subscribe.isChecked() && f.via.selected() == f.sms;
    Stdio.printf(ok ? "PASS: a whole form composes and drives on Win32\n" : "FAIL\n");
    }
