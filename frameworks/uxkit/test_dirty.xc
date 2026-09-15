// test_dirty.xc — setNeedsDisplay must repaint ONE VIEW, not the window.
//
// Two sibling views, far apart.  Mark ONE dirty.  The other's drawRect must NOT run.
// That is the whole difference between "typing a character repaints a line" and
// "typing a character repaints every view in the window and throws the pixels away".
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXControl.xc"
#import "UXBoot.xc"

class Counted : UXView
    {
    u16 draws;
    i32 tag;
    void init(void)
        {
        super.init();
        draws = (u16)0;
        tag = (i32)0;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        draws = draws + (u16)1;
        g.fillRect(self.bounds(), (i32)(2 + tag));
        }
    }

    class Controller : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    Counted* top;
    Counted* bottom;

    void init(void)
        {
        }

    i32 applicationDidStart(UXApplication* a)
        {
        i32 sw = a.screenWidth();
        i32 sh = a.screenHeight();

        UXView* content = new UXView();
        win = new UXWindow();
        a.addWindow(win);
        win.open("dirty", UXGeom.make((i16)2, (i16)2, (i16)(sw - (i32)4), (i16)(sh - (i32)4)), content);

        top = new Counted();
        top.tag = (i32)0;
        bottom = new Counted();
        bottom.tag = (i32)1;
        content.addSubview(top, UXGeom.make((i16)5, (i16)5, (i16)40, (i16)20));
        content.addSubview(bottom, UXGeom.make((i16)5, (i16)60, (i16)40, (i16)20));
        win.tree.finalise();
        win.displayAll(); // first paint: BOTH must draw

        u16 t0 = top.draws;
        u16 b0 = bottom.draws;
        Stdio.printf("after full repaint : top=%d bottom=%d (both should have drawn)\n",
                     (i16)t0, (i16)b0);

        // ---- now mark ONLY the top view dirty --------------------------------
        UXRect af = top.absoluteFrame();
        Stdio.printf("top.absoluteFrame() = %d,%d %dx%d  (index=%d)\n",
                     af.x, af.y, af.w, af.h, (i16)top.index);
        top.setNeedsDisplay();
        UXRect d = win.tree.dirty;
        Stdio.printf("dirty rect = %d,%d %dx%d   (top's frame, NOT the window)\n",
                     d.x, d.y, d.w, d.h);
        win.display();

        u16 t1 = top.draws;
        u16 b1 = bottom.draws;
        Stdio.printf("after 1 view dirty : top=%d (+%d) bottom=%d (+%d)\n",
                     (i16)t1, (i16)(t1 - t0), (i16)b1, (i16)(b1 - b0));

        bool onlyTop = (t1 > t0) && (b1 == b0);
        bool tight = d.w < (i16)(sw / (i32)2) && d.h < (i16)(sh / (i32)2);

        if (onlyTop && tight)
            {
            Stdio.printf("PASS: one view marked dirty repainted ONE view.\n");
            Stdio.printf("      The other's drawRect never ran, and the damage rect\n");
            Stdio.printf("      is the view's, not the window's.\n");
            }
        else
            {
            Stdio.printf("FAIL: onlyTop=%d tight=%d\n", (i16)(onlyTop ? 1 : 0), (i16)(tight ? 1 : 0));
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
