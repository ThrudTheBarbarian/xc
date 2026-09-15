// test_focus.xc — keyboard navigation: the Tab ring and the default button.
//
// Both are NEUTRAL (§5): tree order is tab order, acceptsFirstResponder() picks the stops,
// and the default button is an app-declared role that Return fires.  No driver, no drawing —
// the window walks its own view tree and moves the first responder.
#import <Stdio.xc>
#import <GEM>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXControl.xc"
#import "UXBoot.xc"

class Controller : Object<UXApplicationDelegate>
    {
    i32 fired;
    void init(void)
        {
        fired = (i32)0;
        }
    void onDefault(UXControl* s)
        {
        fired = fired + (i32)1;
        }

    i32 applicationDidStart(UXApplication* a)
        {
        i32 sw = a.screenWidth();
        i32 sh = a.screenHeight();

        UXView* content = new UXView();
        UXWindow* win = new UXWindow();
        a.addWindow(win);
        win.open("focus", UXGeom.make((i16)2, (i16)2, (i16)(sw - (i32)4), (i16)(sh - (i32)4)), content);

        // index 1,2 = two fields (tab stops); index 3 = a button (NOT a stop, but the default)
        UXTextField* f1 = new UXTextField();
        content.addSubview(f1, UXGeom.make((i16)8, (i16)8, (i16)80, (i16)18));
        UXTextField* f2 = new UXTextField();
        content.addSubview(f2, UXGeom.make((i16)8, (i16)30, (i16)80, (i16)18));
        UXButton* ok = new UXButton();
        ok.setTitle("OK");
        ok.setAction(&self.onDefault);
        content.addSubview(ok, UXGeom.make((i16)8, (i16)52, (i16)50, (i16)18));
        win.tree.finalise();
        win.displayAll();
        win.setDefaultButton(ok);

        Stdio.printf("1. start: firstResponder set? %d (expect 0)\n",
                     (i16)(win.firstResponder != (UXResponder*)0 ? 1 : 0));

        UXEvent* tab = new UXEvent();
        tab.kind = (u8)UXEventKeyDown;
        tab.key = (u16)UX_KEY_TAB;
        tab.modifiers = (u16)0;

        win.dispatchKey(tab);
        bool on1 = ((UXResponder*)f1 == win.firstResponder);
        Stdio.printf("2. Tab -> field 1? %d\n", (i16)(on1 ? 1 : 0));

        win.dispatchKey(tab);
        bool on2 = ((UXResponder*)f2 == win.firstResponder);
        Stdio.printf("3. Tab -> field 2? %d\n", (i16)(on2 ? 1 : 0));

        win.dispatchKey(tab); // button is not a stop -> wraps past it to f1
        bool wrap = ((UXResponder*)f1 == win.firstResponder);
        Stdio.printf("4. Tab wraps past the button -> field 1? %d\n", (i16)(wrap ? 1 : 0));

        UXEvent* stab = new UXEvent();
        stab.kind = (u8)UXEventKeyDown;
        stab.key = (u16)UX_KEY_TAB;
        stab.modifiers = (u16)UX_MOD_SHIFT;
        win.dispatchKey(stab); // Shift-Tab from f1 -> previous stop = f2
        bool back = ((UXResponder*)f2 == win.firstResponder);
        Stdio.printf("5. Shift-Tab -> field 2? %d\n", (i16)(back ? 1 : 0));

        UXEvent* ret = new UXEvent();
        ret.kind = (u8)UXEventKeyDown;
        ret.key = (u16)UX_KEY_RETURN;
        ret.modifiers = (u16)0;
        win.dispatchKey(ret); // Return fires the default button
        Stdio.printf("6. Return -> default button fired = %d (expect 1)\n", fired);

        if (on1 && on2 && wrap && back && fired == (i32)1)
            {
            Stdio.printf("PASS: Tab ring + Shift-Tab + Return-fires-default, all neutral logic.\n");
            }
        else
            {
            Stdio.printf("FAIL: on1=%d on2=%d wrap=%d back=%d fired=%d\n",
                         (i16)(on1 ? 1 : 0), (i16)(on2 ? 1 : 0), (i16)(wrap ? 1 : 0), (i16)(back ? 1 : 0), fired);
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
    gDriver = new UXGemDriver(); // select the GEM backend (UXApplication is neutral)
    UXApplication* app = new UXApplication();
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run();
    }
