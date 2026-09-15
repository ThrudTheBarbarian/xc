// nibdemo.xc — a dialog designed in Rocks, running as a live view hierarchy.
//
// The .rsc is not converted into anything.  Its OBJECT tree IS the view tree: the
// AES draws it, hit-tests it, and themes every widget in it, while Xtg binds an
// UXView onto each object so it has behaviour and a place in the responder chain.
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXNib.xc"
#import "UXBoot.xc"

class Controller : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    u16 fired;

    void init(void)
        {
        fired = (u16)0;
        }

    i32 applicationDidStart(UXApplication* a)
        {
        i32 sw = a.screenWidth();
        i32 sh = a.screenHeight();

        // The desktop's own resource — the very file Rocks reads and writes.
        UXViewTree* vt = UXNib.load("/System/OS/Apps/Desktop/desktop.rsc", (i32)0);
        if (vt == (UXViewTree*)0)
            {
            Stdio.printf("could not load the .rsc\n");
            a.stop();
            return (i32)1;
            }
        Stdio.printf("loaded tree 0 from desktop.rsc: %d objects\n", (i16)vt.length());

        // What did the resource actually give us?
        u16 buttons = (u16)0;
        for (u16 i = (u16)0; i < vt.length(); i++)
            {
            u16 ty = (u16)(((OBJECT*)vt.objects())[i].ob_type & (u16)$00FF);
            if (ty == (u16)G_BUTTON)
                {
                buttons = buttons + (u16)1;
                }
            }
        Stdio.printf("  of which %d are G_BUTTONs — GEM themes every one of them\n",
                     (i16)buttons);

        win = new UXWindow();
        a.addWindow(win);
        win.openWithTree("From Rocks",
                         UXGeom.make((i16)4, (i16)4, (i16)(sw - (i32)8), (i16)(sh - (i32)8)),
                         vt);

        // Wire behaviour onto a control the RESOURCE created.  The view already
        // exists — the nib made it — we are only giving it something to do.
        for (u16 i = (u16)0; i < vt.length(); i++)
            {
            u16 ty = (u16)(((OBJECT*)vt.objects())[i].ob_type & (u16)$00FF);
            if (ty != (u16)G_BUTTON)
                {
                continue;
                }
            UXButton* b = (UXButton* ?)vt.viewAt(i);
            if (b == (UXButton*)0)
                {
                continue;
                }
            b.setAction(&self.onButton); // bound method
            Stdio.printf("  wired a button at object %d\n", (i16)i);
            }

        // Click the first button, through the real path: objc_find -> view ->
        // responder chain -> target/action.
        for (u16 i = (u16)0; i < vt.length(); i++)
            {
            if ((u16)(((OBJECT*)vt.objects())[i].ob_type & (u16)$00FF) != (u16)G_BUTTON)
                {
                continue;
                }
            UXView* v = win.viewAt(i);
            UXRect r = v.absoluteFrame();
            UXEvent* e = new UXEvent();
            e.kind = (u8)UXEventMouseDown;
            e.x = (i16)(r.x + r.w / (i16)2);
            e.y = (i16)(r.y + r.h / (i16)2);
            Stdio.printf("clicking the button at %d,%d\n", e.x, e.y);
            win.dispatchMouse(e);
            break;
            }

        if (vt.length() > (u16)0 && buttons > (u16)0 && fired == (u16)1)
            {
            Stdio.printf("PASS: a Rocks-authored .rsc is a LIVE view hierarchy.\n");
            Stdio.printf("      GEM drew it; objc_find hit-tested it; our action fired.\n");
            }
        else
            {
            Stdio.printf("FAIL: objects=%d buttons=%d fired=%d\n",
                         (i16)vt.length(), (i16)buttons, (i16)fired);
            }
        a.stop();
        return (i32)0;
        }

    void onButton(UXControl* sender)
        {
        fired = fired + (u16)1;
        Stdio.printf("  action fired from a button the RESOURCE created\n");
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
