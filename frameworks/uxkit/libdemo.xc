// demo.xc — an Xtg application.  This is what writing for the XT looks like.
#import <Stdio.xc>
#import <UXKit>
#import "UXAbi.xc" // the ABI stamp libUXKit.so must match (generated)
#import "UXBoot.xc"

// A custom view: we override drawRect and the AES calls it.
class SwatchView : UXView
    {
    i32 pen;
    u16 draws;

    void init(void)
        {
        super.init();
        pen = (i32)2;
        draws = (u16)0;
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        draws = draws + (u16)1;
        g.fillRect(self.bounds(), pen);
        g.drawText("custom view", (i16)6, (i16)6, (i32)1, (i32)10);
        }

    void cycle(void)
        {
        pen = pen + (i32)1;
        if (pen > (i32)6)
            {
            pen = (i32)2;
            }
        self.setNeedsDisplay();
        }
    }

    class Controller : Object<UXApplicationDelegate>
    {
    weak : UXApplication* app;
    UXWindow* win;
    SwatchView* swatch;
    u16 clicks;

    void init(void)
        {
        clicks = (u16)0;
        }

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        i32 sw = a.screenWidth();
        i32 sh = a.screenHeight();

        UXView* content = new UXView();
        content.setNextResponder((UXResponder*)0);

        win = new UXWindow();
        a.addWindow(win);
        win.open("Xtg demo",
                 UXGeom.make((i16)4, (i16)4, (i16)(sw - (i32)8), (i16)(sh - (i32)8)),
                 content);

        swatch = new SwatchView();
        content.addSubview(swatch, UXGeom.make((i16)8, (i16)8, (i16)70, (i16)34));

        UXButton* b = new UXButton();
        b.setTitle("Cycle");
        b.setAction(&self.onClick); // a bound method.  No downcast, no selector.
        content.addSubview(b, UXGeom.make((i16)8, (i16)50, (i16)56, (i16)18));

        win.tree.finalise();
        win.display();

        Stdio.printf("window up: %d objects; swatch drawn %d time(s)\n",
                     (i16)win.tree.length(), (i16)swatch.draws);

        // Drive it without a mouse: hit-test where the button is, dispatch, and
        // watch the action fire and the custom view repaint.
        UXRect bf = b.absoluteFrame();
        UXEvent* e = new UXEvent();
        e.kind = (u8)UXEventMouseDown;
        e.x = (i16)(bf.x + bf.w / (i16)2);
        e.y = (i16)(bf.y + bf.h / (i16)2);
        Stdio.printf("synthetic click at %d,%d (over the G_BUTTON)\n", e.x, e.y);
        win.dispatchMouse(e);
        win.dispatchMouse(e);

        u16 before = swatch.draws;
        win.display();
        Stdio.printf("swatch drawRect called %d time(s) total\n", (i16)swatch.draws);

        if (clicks == (u16)2 && swatch.draws > before && swatch.pen == (i32)4)
            {
            Stdio.printf("PASS: hit-test -> responder -> target/action -> setNeedsDisplay\n");
            Stdio.printf("      -> the AES redrew, calling our drawRect.  A toolkit.\n");
            }
        else
            {
            Stdio.printf("FAIL: clicks=%d pen=%d draws=%d\n",
                         (i16)clicks, (i16)swatch.pen, (i16)swatch.draws);
            }
        a.stop();
        return (i32)0;
        }

    // The action is now an ordinary method on the controller.  It used to be a free
    // function taking `Object* t` and downcasting to recover self, because xtc could
    // not take the address of a method — `callback` removes that entirely.
    void onClick(UXControl* sender)
        {
        clicks = clicks + (u16)1;
        swatch.cycle(); // -> setNeedsDisplay, coalesced
        Stdio.printf("  button fired: click %d, swatch pen now %d\n",
                     (i16)clicks, (i16)swatch.pen);
        }
    }

    void
    main(void)
    {
    // THE VERSION GATE. Calling this references UXKit_abi_<major>_<minor>, so if libUXKit.so has
    // had an ABI break since we were compiled, the LOADER rejects us by name before main()
    // runs — instead of PC=0 in a stale vtable. The argument is the minimum PATCH we need,
    // and a newer patch is fine.
    if (!ux_require((i32)0))
        {
        Stdio.printf("libdemo: libUXKit.so is too old\n");
        return;
        }

    // qemu has no SD card, so init started no gemd.  TEST-ONLY (UXBoot.xc).
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }

    UXApplication* app = new UXApplication();
    app.setDriver(new UXGemDriver()); // GEM backend (lib client cannot name the gDriver global)
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run();
    }
