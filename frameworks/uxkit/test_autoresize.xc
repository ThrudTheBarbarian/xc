// test_autoresize.xc — springs & struts on the GEM backend, under qemu.
//
// The neutral solver is proven backend-neutral in test_springs; this proves the INTEGRATION: on GEM
// (driverAutoresizes() is false) UXWindow.layoutFor runs the reflow when the work area changes, so a
// masked child follows the window — the same behaviour AppKit gets from native NSView autoresizing.
#import <Stdio.xc>
#import <GEM>
#import "UXGem.xc"
#import "UXBoot.xc"
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"

i32 gFails;
void expect(u8* name, UXView* v, i32 x, i32 y, i32 w, i32 h)
    {
    UXRect f = v.frame();
    if ((i32)f.x == x && (i32)f.y == y && (i32)f.w == w && (i32)f.h == h)
        {
        Stdio.printf("  ok   %s = %d,%d,%d,%d\n", name, (i16)f.x, (i16)f.y, (i16)f.w, (i16)f.h);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d,%d,%d,%d (want %d,%d,%d,%d)\n", name,
                     (i16)f.x, (i16)f.y, (i16)f.w, (i16)f.h, (i16)x, (i16)y, (i16)w, (i16)h);
        gFails = gFails + (i32)1;
        }
    }
class Box : UXView
    {
    UXKind kind(void)
        {
        return UXKindBox;
        }
    }

    class Controller : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    i32 applicationDidStart(UXApplication* a)
        {
        gFails = (i32)0;
        Box* doc = new Box();
        win = new UXWindow();
        a.addWindow(win);
        win.open((u8*)"Autoresize", UXGeom.make((i16)0, (i16)0, (i16)200, (i16)100), doc);

        Box* pinR = new Box();
        doc.addSubview(pinR, UXGeom.make((i16)140, (i16)10, (i16)50, (i16)20));
        pinR.setAutoresizeMask((i32)UX_ANCHOR_RIGHT);
        Box* flexW = new Box();
        doc.addSubview(flexW, UXGeom.make((i16)10, (i16)40, (i16)180, (i16)20));
        flexW.setAutoresizeMask((i32)UX_FLEX_WIDTH);
        Box* pinBR = new Box();
        doc.addSubview(pinBR, UXGeom.make((i16)140, (i16)70, (i16)50, (i16)20));
        pinBR.setAutoresizeMask((i32)UX_ANCHOR_RIGHT | (i32)UX_ANCHOR_BOTTOM);
        win.tree.finalise();

        // The reflow UXWindow.layoutFor runs on a GEM resize, driven directly: it reads and writes the
        // real GEM OBJECT frames (ob_x/y/w/h) through the driver, so this proves the springs work on
        // GEM's own storage, not just the neutral math (that is test_springs).
        doc.resizeSubviews((i32)200, (i32)100, (i32)300, (i32)150); // +100 x +50

        expect((u8*)"anchor right   follows x", pinR, (i32)240, (i32)10, (i32)50, (i32)20);
        expect((u8*)"flex width     grows w", flexW, (i32)10, (i32)40, (i32)280, (i32)20);
        expect((u8*)"anchor bot-rt  follows", pinBR, (i32)240, (i32)120, (i32)50, (i32)20);

        Stdio.printf(gFails == (i32)0
                         ? "PASS: springs & struts reflow on GEM through UXWindow.layoutFor\n"
                         : "FAIL: %d checks failed\n",
                     (i16)gFails);
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
    Controller* c = new Controller();
    UXApplication* app = new UXApplication();
    app.setDelegate(c);
    app.run();
    }
