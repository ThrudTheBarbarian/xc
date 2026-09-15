// Headless Phase-1 test.  No framebuffer needed: objc_find and objc_offset are
// pure geometry, so the AES can walk and hit-test our tree with no display.
#import <Stdio.xc>
#import "UXView.xc"
#import "UXGemDriver.xc"

u16 gFails;
u16 gChecks;
void ck(bool ok, u8* what)
    {
    gChecks = gChecks + (u16)1;
    if (!ok)
        {
        gFails = gFails + (u16)1;
        Stdio.printf("  FAIL %s\n", what);
        }
    }

// A view that records whether the responder chain reached it.
class ProbeView : UXView
    {
    u16 hits;
    bool consume;

    void init(void)
        {
        super.init();
        hits = (u16)0;
        consume = false;
        }

    void mouseDown(UXEvent* e)
        {
        hits = hits + (u16)1;
        // not mine — pass it up
        if (!consume)
            {
            super.mouseDown(e);
            }
        }
    }

    void
    main(void)
    {
    gFails = (u16)0;
    gChecks = (u16)0;
    gDriver = new UXGemDriver(); // select the backend (no gemd needed for tree ops)

    UXViewTree* t = new UXViewTree();

    // root 0,0 320x200
    ProbeView* root = new ProbeView();
    root.attachTo(t, UXGeom.make((i16)0, (i16)0, (i16)320, (i16)200));

    // a child box at 100,50 and a button inside IT at 10,10 (so abs 110,60)
    ProbeView* box = new ProbeView();
    box.attachTo(t, UXGeom.make((i16)100, (i16)50, (i16)150, (i16)100));
    t.addChild(root.index, box.index);
    box.superview = root;
    box.setNextResponder(root);

    ProbeView* btn = new ProbeView();
    btn.attachTo(t, UXGeom.make((i16)10, (i16)10, (i16)60, (i16)20));
    t.addChild(box.index, btn.index);
    btn.superview = box;
    btn.setNextResponder(box);

    t.finalise();

    // ---- the tree the AES sees ------------------------------------------------
    ck(t.length() == (u16)3, "three objects in the tree");
    ck(((OBJECT*)t.objects())[root.index].ob_head == (i16)box.index, "root's first child is the box");
    ck(((OBJECT*)t.objects())[box.index].ob_head == (i16)btn.index, "box's first child is the button");
    ck(((OBJECT*)t.objects())[btn.index].ob_next == (i16)box.index, "last child points back at its parent");

    // ---- objc_offset: the AES computes absolute position ----------------------
    UXRect abs = btn.absoluteFrame();
    ck(abs.x == (i16)110 && abs.y == (i16)60, "objc_offset: button is at 110,60");

    // ---- objc_find: the AES hit-tests OUR tree --------------------------------
    ck(t.hitTest((i16)120, (i16)65) == (i32)btn.index, "hit inside the button finds it");
    ck(t.hitTest((i16)200, (i16)140) == (i32)box.index, "hit in the box, not the button");
    ck(t.hitTest((i16)5, (i16)5) == (i32)root.index, "hit in the root only");

    // OF_HIDETREE: the AES must skip a hidden subtree
    box.setHidden(true);
    ck(t.hitTest((i16)120, (i16)65) == (i32)root.index, "hidden subtree is not hit");
    box.setHidden(false);
    ck(t.hitTest((i16)120, (i16)65) == (i32)btn.index, "unhidden again");

    // ---- the responder chain ---------------------------------------------------
    UXEvent* e = new UXEvent();

    // nobody consumes: the event must climb button -> box -> root
    btn.mouseDown(e);
    ck(btn.hits == (u16)1 && box.hits == (u16)1 && root.hits == (u16)1,
       "unconsumed event climbs the whole chain");

    // the box consumes: root must NOT see it
    btn.hits = (u16)0;
    box.hits = (u16)0;
    root.hits = (u16)0;
    box.consume = true;
    btn.mouseDown(e);
    ck(btn.hits == (u16)1 && box.hits == (u16)1 && root.hits == (u16)0,
       "a consumer stops the chain");

    // ---- structure change ------------------------------------------------------
    t.removeChild(box.index, btn.index);
    ck(((OBJECT*)t.objects())[box.index].ob_head == (i16)-1, "removeChild unlinks the only child");
    ck(t.hitTest((i16)120, (i16)65) == (i32)box.index, "the AES no longer finds it");

    // ---- damage accumulation ------------------------------------------------
    // The union of what views marked dirty.  Pure logic, no AES — so it is testable
    // even with no window server, and it is where the struct-ternary miscompile bit.
    UXViewTree* d = new UXViewTree();
    ProbeView* a1 = new ProbeView();
    ProbeView* a2 = new ProbeView();
    a1.attachTo(d, UXGeom.make((i16)10, (i16)10, (i16)20, (i16)20));
    a2.attachTo(d, UXGeom.make((i16)100, (i16)100, (i16)20, (i16)20));
    d.addChild(a1.index, a2.index);

    ck(!d.isDirty(), "a fresh tree is clean");
    a1.setNeedsDisplay();
    UXRect r1 = d.dirty;
    ck(d.isDirty() && r1.x == (i16)10 && r1.y == (i16)10 && r1.w == (i16)20 && r1.h == (i16)20,
       "one view dirty -> the damage rect is THAT view");

    a2.setNeedsDisplay(); // a2 sits at 110,110 (child-relative)
    UXRect r2 = d.dirty;
    ck(r2.x == (i16)10 && r2.y == (i16)10 && r2.w == (i16)120 && r2.h == (i16)120,
       "two views dirty -> the UNION of both");

    UXRect taken = d.takeDirty();
    ck(!d.isDirty() && taken.w == (i16)120, "takeDirty returns the union and clears it");
    a1.setNeedsDisplay();
    ck(d.dirty.w == (i16)20, "and the next mark starts fresh, not from the old union");

    // ---- DEEP trees: objc_find past the classic depth of 8 -------------------
    // Classic GEM stopped at 8.  A view hierarchy is deeper than that (window ->
    // content -> scroll -> clip -> table -> row -> cell -> field is eight already), and
    // past the limit the AES silently stops descending: never drawn, never hit-tested.
    UXViewTree* deep = new UXViewTree();
    ProbeView* top = new ProbeView();
    top.attachTo(deep, UXGeom.make((i16)0, (i16)0, (i16)200, (i16)200));
    ProbeView* prev = top;
    ProbeView* last = top;
    // 16 levels deep in total
    for (i32 k = (i32)0; k < (i32)15; k++)
        {
        ProbeView* p = new ProbeView();
        p.attachTo(deep, UXGeom.make((i16)1, (i16)1, (i16)(180 - (i32)2 * k), (i16)(180 - (i32)2 * k)));
        deep.addChild(prev.index, p.index);
        prev = p;
        last = p;
        }
    deep.finalise();
    UXRect la = deep.absoluteFrame(last.index);
    i32 hit = deep.hitTest((i16)(la.x + (i16)2), (i16)(la.y + (i16)2));
    ck(hit == (i32)last.index,
       "objc_find reaches level 16 (classic GEM stopped at 8, silently)");

    Stdio.printf("spine: %d checks, %d failure(s) — %s\n",
                 (i16)gChecks, (i16)gFails, gFails == (u16)0 ? "PASS" : "FAIL");
    }
