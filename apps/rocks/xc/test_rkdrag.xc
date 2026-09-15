// test_rkdrag.xc — direct manipulation, as model logic.
//
// The drag machine is deliberately viewless, so all of this runs headless: no
// window, no driver, no pointer.  What is being asserted is the set of claims a
// designer would notice instantly and a screenshot would not prove — that the
// object stays under the cursor, that it does not creep, that clicking a nested
// control picks the control and not its box, and that an abandoned drag leaves
// the model untouched.
#import <Stdio.xc>
#import "RKModel.xc"
#import "RKDrag.xc"

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

void main(void)
    {
    gFails = (i32)0;

    // A form with a nested box, which is where hit-testing and coordinates get
    // interesting: `kid` lives at (10,10) inside a box at (50,40), so its
    // canvas position is (60,50) and NEITHER number appears in the model.
    RKObject* root = RKObject.make((i32)RKT_BOX, (i32)0, (i32)0, (i32)300, (i32)200);
    RKObject* btn = RKObject.make((i32)RKT_BUTTON, (i32)20, (i32)20, (i32)60, (i32)20);
    RKObject* box = RKObject.make((i32)RKT_BOX, (i32)50, (i32)40, (i32)200, (i32)120);
    RKObject* kid = RKObject.make((i32)RKT_BUTTON, (i32)10, (i32)10, (i32)40, (i32)20);
    RKObject* ghost = RKObject.make((i32)RKT_BUTTON, (i32)20, (i32)60, (i32)60, (i32)20);
    ghost.flags = ghost.flags | (i32)RKF_HIDETREE;
    box.addChild(kid);
    root.addChild(btn);
    root.addChild(box);
    root.addChild(ghost);

    // ---- the tree, read geometrically ---------------------------------------
    checkTrue("parentOf finds a top-level object's parent", RKDrag.parentOf(root, btn) == root);
    checkTrue("and a nested one's", RKDrag.parentOf(root, kid) == box);
    checkTrue("the root has no parent", RKDrag.parentOf(root, root) == (RKObject*)0);

    i32 ax = (i32)0;
    i32 ay = (i32)0;
    checkTrue("absOrigin resolves a nested object", RKDrag.absOrigin(root, kid, &ax, &ay));
    check("its canvas x is the sum of the chain", ax, (i32)60);
    check("and its canvas y", ay, (i32)50);

    // ---- hit-testing ---------------------------------------------------------
    checkTrue("a click on a control picks it", RKDrag.hitTest(root, (i32)30, (i32)25) == btn);
    // DEEPEST WINS: (70,60) is inside the box AND inside its child.  Picking the
    // box would make a nested control unselectable by clicking it.
    checkTrue("a click inside a box picks the CHILD, not the box",
              RKDrag.hitTest(root, (i32)70, (i32)60) == kid);
    checkTrue("a click on box background picks the box",
              RKDrag.hitTest(root, (i32)200, (i32)140) == box);
    checkTrue("a click on bare form is nothing (so it deselects)",
              RKDrag.hitTest(root, (i32)280, (i32)10) == (RKObject*)0);
    // A hidden object is not on screen; letting it take the press would mean
    // clicking empty space and selecting something invisible.
    checkTrue("a hidden object cannot be clicked",
              RKDrag.hitTest(root, (i32)30, (i32)65) == (RKObject*)0);

    // ---- handles -------------------------------------------------------------
    UXRect r = UXGeom.make((i16)20, (i16)20, (i16)60, (i16)20);
    check("the top-left corner grabs handle 0", RKDrag.handleAt(r, (i32)20, (i32)20), (i32)0);
    check("the bottom-right grabs handle 3", RKDrag.handleAt(r, (i32)80, (i32)40), (i32)3);
    check("the middle grabs nothing", RKDrag.handleAt(r, (i32)50, (i32)30), (i32)-1);
    checkTrue("the hot zone reaches OUTSIDE the rect, so small objects stay resizable",
              RKDrag.handleAt(r, (i32)18, (i32)18) == (i32)0);

    // ---- moving --------------------------------------------------------------
    RKDrag* d = new RKDrag();
    d.snapOn = false; // exact follow, no magnet
    checkTrue("snapping is ON by default", (new RKDrag()).snapOn);
    checkTrue("and so are guides", (new RKDrag()).guidesOn);

    // Press 10px into the button, drag 100 right and 50 down.
    RKObject* got = d.begin(root, (RKObject*)0, (i32)30, (i32)25);
    checkTrue("the press picks the button", got == btn);
    checkTrue("and the drag is live", d.isDragging());
    d.step((i32)130, (i32)75);
    check("the object moved by the POINTER's delta, x", btn.x, (i32)120);
    check("and y", btn.y, (i32)70);
    // THE GRAB OFFSET: the press was 10px in, so the object must not have
    // snapped its corner to the cursor.  A jump on mouse-down is the single
    // most obvious way for a drag to feel broken.
    check("the grab offset is preserved (no jump to the cursor)",
          (i32)130 - btn.x, (i32)10);

    // THE CREEP TEST: every step recomputes from the press, so stepping to the
    // same place twice must give the same answer.  A delta-accumulating drag
    // passes the first step and fails this one.
    d.step((i32)130, (i32)75);
    check("stepping to the same point twice does not move it again", btn.x, (i32)120);
    d.step((i32)140, (i32)85);
    d.step((i32)130, (i32)75);
    check("and going out and back lands exactly where it was", btn.x, (i32)120);
    d.end();
    checkTrue("releasing ends the drag", !d.isDragging());

    // ---- moving a NESTED object works in its parent's space ------------------
    RKDrag* dn = new RKDrag();
    dn.snapOn = false;
    dn.begin(root, (RKObject*)0, (i32)70, (i32)60); // on `kid`
    dn.step((i32)100, (i32)90);
    // Canvas (100,90) with a 10/10 grab, inside a box at (50,40): the model
    // must hold PARENT-relative coordinates, not canvas ones.
    check("a nested object stores parent-relative x", kid.x, (i32)40);
    check("and parent-relative y", kid.y, (i32)40);
    dn.end();

    // ---- snapping and guides, through the drag -------------------------------
    kid.x = (i32)40;
    kid.y = (i32)40;
    RKDrag* ds = new RKDrag();                                          // snapping left ON
    ds.begin(root, (RKObject*)0, (i32)60 + (i32)40, (i32)50 + (i32)40); // grab 0,0 corner
    // Aim so the OBJECT's origin lands at parent-relative (2,2) -- close enough
    // that the box's own top-left should catch it.  The pointer goes 10 further
    // than the target, because that is where it was grabbed; forgetting the
    // grab offset here is the same mistake that makes a drag jump.
    ds.step((i32)50 + (i32)12, (i32)40 + (i32)12);
    check("a near-miss snaps to the parent's edge, x", kid.x, (i32)0);
    check("and y", kid.y, (i32)0);
    checkTrue("guides were published", (i32)ds.guides.count() > (i32)0);
    // Guides are reported in CANVAS coordinates: the box's left edge is
    // parent-relative 0 but canvas 50, and the overlay draws in canvas space.
    bool foundV = false;
    for (i32 i = (i32)0; i < (i32)ds.guides.count(); i = i + (i32)1)
        {
        RKGuide* g = (RKGuide* ?)ds.guides.get((u16)i);
        if (g.vertical && g.pos == (i32)50)
            {
            foundV = true;
            }
        }
    checkTrue("a guide is offset into canvas coordinates, not left parent-relative", foundV);
    ds.end();
    check("ending clears the guides", (i32)ds.guides.count(), (i32)0);

    // Turning snapping off must actually reach the geometry, not just the menu.
    kid.x = (i32)40;
    kid.y = (i32)40;
    RKDrag* dq = new RKDrag();
    dq.snapOn = false;
    dq.begin(root, (RKObject*)0, (i32)100, (i32)90);
    dq.step((i32)62, (i32)52);
    check("with snapping off the object goes exactly where asked", kid.x, (i32)2);
    check("and reports no guides", (i32)dq.guides.count(), (i32)0);
    dq.end();

    // ---- resizing ------------------------------------------------------------
    btn.x = (i32)20;
    btn.y = (i32)20;
    btn.w = (i32)60;
    btn.h = (i32)20;
    RKDrag* dr = new RKDrag();
    dr.snapOn = false;
    // Press the button's bottom-right handle WITH the button selected.  The
    // point is on the handle, which is drawn on top, so it must resize even
    // though a plain hit-test at that point would also find the button.
    RKObject* rt = dr.begin(root, btn, (i32)80, (i32)40);
    checkTrue("a press on a handle targets the selection", rt == btn);
    dr.step((i32)150, (i32)70);
    check("the origin is FIXED while resizing, x", btn.x, (i32)20);
    check("and y", btn.y, (i32)20);
    check("the width follows the pointer", btn.w, (i32)130);
    check("and the height", btn.h, (i32)50);
    // Dragging the handle past the origin must not invert the rect.
    dr.step((i32)0, (i32)0);
    checkTrue("dragging a handle past the origin never inverts the rect",
              btn.w > (i32)0 && btn.h > (i32)0);
    dr.end();

    // A handle press wins over whatever is UNDER the point: the handles of a
    // selected object overlap its neighbours, and the designer is aiming at
    // what is drawn on top.
    btn.x = (i32)20;
    btn.y = (i32)20;
    btn.w = (i32)60;
    btn.h = (i32)20;
    RKObject* nbr = RKObject.make((i32)RKT_BUTTON, (i32)78, (i32)38, (i32)40, (i32)20);
    root.addChild(nbr);
    RKDrag* dh = new RKDrag();
    checkTrue("with nothing selected, that point picks the neighbour",
              RKDrag.hitTest(root, (i32)80, (i32)40) == nbr);
    checkTrue("but with the button selected, its handle wins",
              dh.begin(root, btn, (i32)80, (i32)40) == btn);
    dh.end();

    // ---- an abandoned drag leaves nothing behind -----------------------------
    btn.x = (i32)20;
    btn.y = (i32)20;
    btn.w = (i32)60;
    btn.h = (i32)20;
    RKDrag* dc = new RKDrag();
    dc.snapOn = false;
    dc.begin(root, (RKObject*)0, (i32)30, (i32)25);
    dc.step((i32)200, (i32)150);
    checkTrue("a moved drag reports that it moved", dc.didMove());
    dc.cancel();
    check("cancelling restores x", btn.x, (i32)20);
    check("cancelling restores y", btn.y, (i32)20);
    check("cancelling restores w", btn.w, (i32)60);
    check("cancelling restores h", btn.h, (i32)20);

    // A press that lands on nothing is not a drag, and must not move whatever
    // happened to be dragged last.
    RKDrag* db = new RKDrag();
    checkTrue("a press on background targets nothing",
              db.begin(root, (RKObject*)0, (i32)285, (i32)8) == (RKObject*)0);
    checkTrue("and no drag is in progress", !db.isDragging());
    db.step((i32)10, (i32)10); // must be harmless
    check("stepping a dead drag moves nothing", btn.x, (i32)20);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: objects follow the pointer, stay in their parent's space, and snap\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
