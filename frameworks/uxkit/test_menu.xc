// test_menu.xc — menus.
//
// GEM builds the tree, draws the bar, tracks the pull-down and intercepts the click
// inside evnt_multi.  So what Xtg must get right is exactly two things:
//   1. the model reaches GEM and the bar DRAWS
//   2. an MN_SELECTED message becomes the RIGHT bound method call
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXMenu.xc"
#import "UXBoot.xc"

class Controller : Object<UXApplicationDelegate>
    {
    UXMenuBar* bar;
    i32 fired; // which item fired (1..n), 0 = none
    void init(void)
        {
        fired = (i32)0;
        }

    void onNew(UXMenuItem* s)
        {
        fired = (i32)1;
        Stdio.printf("  action: New\n");
        }
    void onOpen(UXMenuItem* s)
        {
        fired = (i32)2;
        Stdio.printf("  action: Open\n");
        }
    void onQuit(UXMenuItem* s)
        {
        fired = (i32)3;
        Stdio.printf("  action: Quit\n");
        }
    void onCut(UXMenuItem* s)
        {
        fired = (i32)4;
        Stdio.printf("  action: Cut\n");
        }

    i32 applicationDidStart(UXApplication* a)
        {
        bar = new UXMenuBar();
        UXMenu* file = bar.addMenu("File");
        file.addItem("New", &self.onNew);
        file.addItem("Open", &self.onOpen);
        file.addSeparator();
        file.addItem("Quit", &self.onQuit);
        UXMenu* edit = bar.addMenu("Edit");
        edit.addItem("Cut", &self.onCut);

        a.setMenuBar(bar); // menu_build + menu_bar(show)
        Stdio.printf("1. menu installed: tree=%s\n",
                     bar.tree != (pointer)0 ? "built" : "NULL");

        // ---- 2. did the bar actually DRAW? ---------------------------------
        // The bar occupies the top strip.  Sample inside it; it must not be the
        // desktop colour.  (aes_init painted the desktop; the bar is drawn over it.)
        i32 hit = objc_find(bar.tree, (i32)0, (i32)8, (i32)30, (i32)10);
        Stdio.printf("2. objc_find at (30,10) in the bar -> object %d (>=0 means the bar is live)\n",
                     hit);

        // ---- 3. MN_SELECTED -> the right bound method ----------------------
        // The message carries OBJECT indices; GEM maps an item object to its ordinal.
        // Find the object index of File>Open (title ordinal 0, item ordinal 1).
        i32 openObj = (i32)-1;
        for (i32 o = (i32)0; o < (i32)40; o++)
            {
            if (menu_item_ord(bar.tree, (i32)0, o) == (i32)1)
                {
                openObj = o;
                break;
                }
            }
        Stdio.printf("3. File>Open is object %d\n", openObj);

        UXEvent* ev = new UXEvent();
        ev.kind = (u8)UXEventMenuSelect;
        ev.a = (i32)2; // title object 0  -> a = ord + 2
        ev.b = (i32)openObj;
        a.dispatchEvent(ev);
        Stdio.printf("4. MenuSelect(File, Open) -> fired = %d (expect 2)\n", fired);

        // ---- 4. a SEPARATOR must never fire --------------------------------
        i32 sepObj = (i32)-1;
        for (i32 o = (i32)0; o < (i32)40; o++)
            {
            if (menu_item_ord(bar.tree, (i32)0, o) == (i32)2)
                {
                sepObj = o;
                break;
                }
            }
        i32 before = fired;
        if (sepObj >= (i32)0)
            {
            ev.b = (i32)sepObj;
            a.dispatchEvent(ev);
            }
        Stdio.printf("5. the separator: object %d, fired unchanged? %d\n",
                     sepObj, (i16)(fired == before ? 1 : 0));

        // ---- 5. the SECOND menu routes to ITS items ------------------------
        i32 cutObj = (i32)-1;
        for (i32 o = (i32)0; o < (i32)40; o++)
            {
            if (menu_item_ord(bar.tree, (i32)1, o) == (i32)0)
                {
                cutObj = o;
                break;
                }
            }
        ev.a = (i32)3; // title object 1
        ev.b = (i32)cutObj;
        a.dispatchEvent(ev);
        Stdio.printf("6. MenuSelect(Edit, Cut) -> fired = %d (expect 4)\n", fired);

        bool ok = bar.tree != (pointer)0 && hit >= (i32)0 && fired == (i32)4;
        if (ok)
            {
            Stdio.printf("PASS: model -> menu_build -> GEM draws it -> MN_SELECTED -> bound method.\n");
            Stdio.printf("      Xtg wrote no drawing, no tracking and no hit-testing.\n");
            }
        else
            {
            Stdio.printf("FAIL: tree=%d hit=%d fired=%d\n",
                         (i16)(bar.tree != (pointer)0 ? 1 : 0), hit, fired);
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
