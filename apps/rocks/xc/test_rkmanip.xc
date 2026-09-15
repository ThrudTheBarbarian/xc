// test_rkmanip.xc — direct manipulation, wired into the real editor.
//
// test_rkdrag.xc proves the geometry.  This proves the WIRING, which is the
// half that fails silently: an overlay that ends up underneath a pane looks
// identical until you click something and the button presses instead of
// selecting, and a selection frame that swallows presses looks identical until
// you try to drag the thing you just selected.
//
// So the claims here are about ORDER and ROUTING, not about arithmetic.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXGeometry.xc"
#import "RKModel.xc"
#import "RKMainController.xc"
#import "RKMainBuilder.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }
void checkTrue(u8* what, bool got)
    {
    if (got)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

// Is `v` the LAST subview of `p`?  That is the whole hit-test question: both
// the driver's tree walk and AppKit's own pick the last matching sibling.
bool isTopmost(UXView* p, UXView* v)
    {
    if ((i32)p.subviews.count() == (i32)0)
        {
        return false;
        }
    return (UXView* ?)p.subviews.get((u16)((i32)p.subviews.count() - (i32)1)) == v;
    }

void main(void)
    {
    gFails = (i32)0;
    ux_ak_set_capture((i32)1);
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no AppKit boot\n");
        return;
        }

    RKMainController* c = new RKMainController();
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"manip", UXGeom.make((i16)0, (i16)0, (i16)900, (i16)600), content);
    checkTrue("the window wires", RKMainBuilder.buildInto(content, c, (i16)900, (i16)600));

    // Two forms, so the lazily-created SECOND pane can try to bury the overlay.
    RKResource* r = new RKResource();
    RKTree* t0 = new RKTree();
    RKObject* root0 = RKObject.make((i32)RKT_BOX, (i32)0, (i32)0, (i32)300, (i32)200);
    RKObject* btn = RKObject.make((i32)RKT_BUTTON, (i32)20, (i32)20, (i32)60, (i32)20);
    RKObject* fld = RKObject.make((i32)RKT_FIELD, (i32)20, (i32)80, (i32)120, (i32)22);
    btn.text = (u8*)"OK";
    root0.addChild(btn);
    root0.addChild(fld);
    t0.root = root0;
    r.addTree(t0);

    RKTree* t1 = new RKTree();
    RKObject* root1 = RKObject.make((i32)RKT_BOX, (i32)0, (i32)0, (i32)300, (i32)200);
    RKObject* other = RKObject.make((i32)RKT_BUTTON, (i32)10, (i32)10, (i32)50, (i32)20);
    root1.addChild(other);
    t1.root = root1;
    r.addTree(t1);

    c.showResource(r, (i32)0);
    win.tree.finalise();

    // ---- the overlay is on top ----------------------------------------------
    checkTrue("the overlay is the canvas's topmost child", isTopmost(c.canvas, (UXView*)c.overlay));
    checkTrue("and it does not take the keyboard", !c.overlay.acceptsFirstResponder());
    checkTrue("it knows which form it is editing", c.overlay.drag.root == root0);
    // Asserted HERE, before anything in this test touches them: an editor
    // whose snapping has to be switched on is an editor whose first form is
    // one pixel out everywhere.
    checkTrue("snapping starts on", c.snapEnabled());
    checkTrue("guides start on", c.guidesEnabled());

    // Switching forms creates a SECOND pane.  If the overlay were simply added
    // once and forgotten, that new pane would land on top of it and every
    // click would go back to the live widgets.
    c.showResource(r, (i32)1);
    checkTrue("after a form switch the overlay is STILL topmost",
              isTopmost(c.canvas, (UXView*)c.overlay));
    checkTrue("and it now edits the other form", c.overlay.drag.root == root1);
    c.showResource(r, (i32)0);
    checkTrue("and back again", c.overlay.drag.root == root0);

    // ---- a press selects, rather than pressing ------------------------------
    // Routed through the overlay's own callback, which is what a real click
    // reaches after the driver's hit-test.
    c.onPick(RKDrag.hitTest(root0, (i32)30, (i32)25));
    checkTrue("clicking a button SELECTS it", c.selectedObject() == btn);
    checkTrue("the inspector followed", c.inspectorCtl.rowNamed((u8*)"Default") != (RKRow*)0);
    checkTrue("the selection frame is showing", !c.selFrame.isHidden());
    check("and sits over the widget, x", (i32)c.selFrame.frame().x, (i32)20);

    // The frame is drawn above the overlay so its handles are visible...
    checkTrue("the selection frame draws above the overlay",
              isTopmost(c.canvas, (UXView*)c.selFrame));
    // ...which makes it the thing a handle press hits, so it must pass the
    // press on rather than swallowing it.  Without this, a selected object
    // becomes the one object in the form you cannot drag.
    checkTrue("and it forwards its presses instead of eating them", c.selFrame.press);

    // Clicking bare form background deselects.
    c.onPick(RKDrag.hitTest(root0, (i32)280, (i32)190));
    checkTrue("clicking the background deselects", c.selectedObject() == (RKObject*)0);
    checkTrue("and hides the frame", c.selFrame.isHidden());

    // ---- a drag moves the MODEL and the WIDGET together ---------------------
    c.onPick(btn);
    c.overlay.setSelection(btn);
    c.overlay.drag.snapOn = false;
    c.overlay.drag.begin(root0, btn, (i32)30, (i32)25);
    c.overlay.drag.step((i32)130, (i32)75);
    c.onDragStep(btn);
    check("the model moved", btn.x, (i32)120);
    UXView* w = c.canvasMap.viewFor(btn);
    check("and the real widget moved with it", (i32)w.frame().x, (i32)120);
    check("as did the selection frame", (i32)c.selFrame.frame().x, (i32)120);
    checkTrue("the document is dirty", c.dirty);

    // Mid-drag the inspector must NOT be rebuilt — the pane the designer is
    // about to read would be destroyed and rebuilt on every pointer step.
    RKRow* rx = c.inspectorCtl.rowNamed((u8*)"X");
    c.overlay.drag.step((i32)140, (i32)85);
    c.onDragStep(btn);
    checkTrue("the inspector survives a drag step", c.inspectorCtl.rowNamed((u8*)"X") == rx);

    // On release it catches up, because the numbers it shows are now stale.
    c.overlay.drag.end();
    c.onDragEnd(btn);
    RKRow* rx2 = c.inspectorCtl.rowNamed((u8*)"X");
    checkTrue("releasing refreshes the inspector", rx2 != (RKRow*)0);
    check("and it reads the object's new position",
          RKInspector.parseInt(rx2.field.text()), btn.x);

    // ---- the toggles --------------------------------------------------------
    c.overlay.drag.snapOn = true; // the drag above turned it off
    c.onToggleSnap((UXMenuItem*)0);
    checkTrue("the menu item turns snapping off", !c.snapEnabled());
    checkTrue("and it reaches the drag machine", !c.overlay.drag.snapOn);
    c.onToggleSnap((UXMenuItem*)0);
    checkTrue("and back on", c.snapEnabled());
    c.onToggleGuides((UXMenuItem*)0);
    checkTrue("guides toggle independently of snapping",
              !c.guidesEnabled() && c.snapEnabled());
    c.onToggleGuides((UXMenuItem*)0);
    checkTrue("and back", c.guidesEnabled());

    // ---- the read-out --------------------------------------------------------
    btn.x = (i32)12;
    btn.y = (i32)34;
    btn.w = (i32)56;
    btn.h = (i32)7;
    u8* g = RKMainController.geomText((u8*)malloc((u32)64), btn);
    Stdio.printf("  ..   the drag read-out says \"%s\"\n", g);
    checkTrue("the read-out starts with the position", g[0] == (u8)49 && g[1] == (u8)50);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the canvas is a design surface — clicks select, drags move, and the overlay stays on top\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
