// test_scale.xc — how does the view hierarchy actually scale?
//
// Three questions, measured rather than assumed:
//   A. DEPTH  — objc_draw is called with depth=8.  Is a deeper tree truncated?
//   B. BREADTH— with N sibling views and ONE dirty, how many drawRects run?
//   C. WALK   — ...and how many objects did the AES VISIT to find that one?
//              The gap between B and C is the cost of the tree walk itself.
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXBoot.xc"

class Probe : UXView
    {
    u16 draws;
    void init(void)
        {
        super.init();
        draws = (u16)0;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        draws = draws + (u16)1;
        g.fillRect(self.bounds(), (i32)2);
        }
    }

    class Controller : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    Array<Probe>* deep; // one view per level
    Array<Probe>* wide; // N siblings
    void init(void)
        {
        deep = new Array();
        wide = new Array();
        }

    i32 applicationDidStart(UXApplication* a)
        {
        i32 sw = a.screenWidth();
        i32 sh = a.screenHeight();
        UXView* content = new UXView();
        win = new UXWindow();
        a.addWindow(win);
        win.open("scale", UXGeom.make((i16)2, (i16)2, (i16)(sw - (i32)4), (i16)(sh - (i32)4)), content);

// ---- A. DEPTH: 16 nested views, each inset 2px ------------------------
#define LEVELS 16
        UXView* parent = content;
        for (i32 i = (i32)0; i < (i32)LEVELS; i++)
            {
            Probe* p = new Probe();
            parent.addSubview(p, UXGeom.make((i16)2, (i16)2,
                                             (i16)(60 - (i32)2 * i), (i16)(60 - (i32)2 * i)));
            deep.add(p);
            parent = p;
            }

// ---- B/C. BREADTH: 100 siblings in a column --------------------------
#define SIBS 100
        for (i32 i = (i32)0; i < (i32)SIBS; i++)
            {
            Probe* p = new Probe();
            content.addSubview(p, UXGeom.make((i16)70, (i16)(1 + i), (i16)8, (i16)1));
            wide.add(p);
            }

        win.tree.finalise();
        Stdio.printf("tree: %d objects\n", (i16)win.tree.length());

        gUserDrawVisits = (u32)0;
        gUserDrawDraws = (u32)0;
        win.displayAll();
        Stdio.printf("FULL repaint : visited=%ld drew=%ld\n", gUserDrawVisits, gUserDrawDraws);

        // A. did the DEEPEST view draw?
        i32 deepest = (i32)0;
        for (i32 i = (i32)0; i < (i32)LEVELS; i++)
            {
            Probe* p = (Probe* ?)deep.get((u16)i);
            if (p.draws > (u16)0)
                {
                deepest = i + (i32)1;
                }
            }
        Stdio.printf("A. DEPTH  : deepest level that drew = %d of %d\n", (i16)deepest, (i16)LEVELS);

        // B/C. mark ONE sibling dirty
        Probe* one = (Probe* ?)wide.get((u16)50);
        for (i32 i = (i32)0; i < (i32)SIBS; i++)
            { Probe* p = (Probe* ?)wide.get((u16)i);
            p.draws = (u16)0;
            }
        gUserDrawVisits = (u32)0;
        gUserDrawDraws = (u32)0;
        one.setNeedsDisplay();
        win.display();
        i32 drew = (i32)0;
        for (i32 i = (i32)0; i < (i32)SIBS; i++)
            {
            Probe* p = (Probe* ?)wide.get((u16)i);
            if (p.draws > (u16)0)
                {
                drew = drew + (i32)1;
                }
            }
        Stdio.printf("B. BREADTH: 1 of %d siblings dirty -> %d drawRect(s) ran\n", (i16)SIBS, (i16)drew);
        Stdio.printf("C. WALK   : the AES VISITED %ld objects to deliver those %ld draws\n",
                     gUserDrawVisits, gUserDrawDraws);
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
