// test_key.xc — the keyboard half of the toolkit, which has never run.
//
// Before this, firstResponder was nil forever and the MU_KEYBD arm dropped every key
// on the floor.  This drives the REAL path: click a field -> it becomes first
// responder -> keys go to it -> objc_edit edits -> the text changes.
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXControl.xc"
#import "UXBoot.xc"

class Controller : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    UXTextField* field;
    UXButton* btn;
    void init(void)
        {
        }

    // Type one character through the SAME path a real keypress takes.
    void type(u16 k)
        {
        UXEvent* e = new UXEvent();
        e.kind = (u8)UXEventKeyDown;
        e.key = k;
        win.dispatchKey(e);
        }

    i32 applicationDidStart(UXApplication* a)
        {
        i32 sw = a.screenWidth();
        i32 sh = a.screenHeight();
        UXView* content = new UXView();
        win = new UXWindow();
        a.addWindow(win);
        win.open("keys", UXGeom.make((i16)2, (i16)2, (i16)(sw - (i32)4), (i16)(sh - (i32)4)), content);

        field = new UXTextField();
        content.addSubview(field, UXGeom.make((i16)8, (i16)8, (i16)120, (i16)20));
        btn = new UXButton();
        btn.setTitle("OK");
        content.addSubview(btn, UXGeom.make((i16)8, (i16)40, (i16)50, (i16)18));
        win.tree.finalise();
        win.displayAll();

        Stdio.printf("1. before any click: firstResponder set? %d (expect 0)\n",
                     (i16)(win.firstResponder != (UXResponder*)0 ? 1 : 0));

        // ---- click the field: it must take the keyboard ----------------------
        UXRect f = field.absoluteFrame();
        UXEvent* click = new UXEvent();
        click.kind = (u8)UXEventMouseDown;
        click.x = (i16)(f.x + f.w / (i16)2);
        click.y = (i16)(f.y + f.h / (i16)2);
        win.dispatchMouse(click);
        bool focused = (win.firstResponder != (UXResponder*)0);
        Stdio.printf("2. clicked the field -> firstResponder set? %d (expect 1)\n",
                     (i16)(focused ? 1 : 0));

        // ---- type "Hi" -------------------------------------------------------
        self.type((u16)72);  // 'H'
        self.type((u16)105); // 'i'
        Stdio.printf("3. typed 'Hi' -> field.text() = \"%s\"\n", field.text());

        // ---- backspace -------------------------------------------------------
        self.type((u16)8); // BS
        Stdio.printf("4. backspace  -> field.text() = \"%s\"\n", field.text());

        // ---- clicking the BUTTON must take the keyboard away -----------------
        UXRect bf = btn.absoluteFrame();
        UXEvent* c2 = new UXEvent();
        c2.kind = (u8)UXEventMouseDown;
        c2.x = (i16)(bf.x + bf.w / (i16)2);
        c2.y = (i16)(bf.y + bf.h / (i16)2);
        win.dispatchMouse(c2);
        bool moved = (win.firstResponder != (UXResponder*)0) && ((UXResponder*)field != win.firstResponder);
        Stdio.printf("5. clicked the button -> focus left the field? %d\n", (i16)(moved ? 1 : 0));

        u8* t = field.text();
        bool ok = focused && t[0] == (u8)72 && t[1] == (u8)0 // "H" after the backspace
                  && !moved;                                 // a BUTTON does not take focus
        // a plain UXButton does NOT accept first responder, so focus should STAY on the field
        bool stillField = ((UXResponder*)field == win.firstResponder);
        Stdio.printf("6. focus still on the field? %d (a button does not steal it)\n",
                     (i16)(stillField ? 1 : 0));

        if (focused && t[0] == (u8)72 && t[1] == (u8)0 && stillField)
            {
            Stdio.printf("PASS: click -> first responder -> keyDown -> objc_edit -> text.\n");
            Stdio.printf("      The keyboard half of the responder chain is real.\n");
            }
        else
            {
            Stdio.printf("FAIL: focused=%d text=\"%s\" stillField=%d\n",
                         (i16)(focused ? 1 : 0), t, (i16)(stillField ? 1 : 0));
            }
        a.stop();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    // qemu has no SD card, so init started no gemd.  TEST-ONLY (UXBoot.xc).
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }

    gDriver = new UXGemDriver(); // select the GEM backend (UXApplication is neutral)
    UXApplication* app = new UXApplication();
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run();
    }
