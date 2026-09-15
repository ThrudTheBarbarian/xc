// test_rkguides.xc — snapping and alignment guides, as pure geometry.
//
// Worth testing hard precisely because it is the part of direct manipulation
// nobody can check by hand: while you are dragging a mouse you cannot tell
// "snapped to the right edge" from "snapped to a nearby wrong one", and both
// look plausible.
#import <Stdio.xc>
#import "RKGuides.xc"

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

Array<RKRectBox>* one(UXRect r)
    {
    Array<RKRectBox>* a = new Array();
    a.add(RKRectBox.of(r));
    return a;
    }

void main(void)
    {
    gFails = (i32)0;
    UXRect parent = UXGeom.make((i16)0, (i16)0, (i16)200, (i16)100);
    Array<RKRectBox>* none = new Array();

    // ---- the toggle is honoured at the source ------------------------------
    UXRect r = UXGeom.make((i16)3, (i16)3, (i16)40, (i16)20);
    UXRect off = RKGuides.snapMove(r, none, parent, false, new Array());
    check("snapping off leaves x alone", (i32)off.x, (i32)3);
    check("snapping off leaves y alone", (i32)off.y, (i32)3);

    // ---- the parent's own edges ---------------------------------------------
    Array<RKGuide>* g = new Array();
    UXRect on = RKGuides.snapMove(r, none, parent, true, g);
    check("near the parent's left edge, it sticks", (i32)on.x, (i32)0);
    check("and its top", (i32)on.y, (i32)0);
    check("two guides were reported", (i32)g.count(), (i32)2);

    // Centring: a 40-wide rect near the parent's centre line (100) should land
    // at 80, not at 100 — the CENTRE snaps, so the origin moves by half.
    UXRect mid = UXGeom.make((i16)82, (i16)40, (i16)40, (i16)20);
    UXRect cs = RKGuides.snapMove(mid, none, parent, true, new Array());
    check("a rect near the centre line is CENTRED, not left-aligned", (i32)cs.x, (i32)80);

    // ---- nothing near means no movement ------------------------------------
    // Genuinely clear of every line: in a 200x100 parent the vertical lines are
    // 0/100/200 and the horizontal ones 0/50/100, and BOTH the centre and the
    // trailing edge count -- (57,41) looks empty but its right edge is 3px from
    // 200-ish and its middle 1px from 50, so it snaps.  Being far means all
    // three edges are far.
    UXRect far = UXGeom.make((i16)30, (i16)20, (i16)40, (i16)20);
    UXRect fs = RKGuides.snapMove(far, none, parent, true, new Array());
    check("well away from any line, x is untouched", (i32)fs.x, (i32)30);
    check("and y", (i32)fs.y, (i32)20);

    // ---- a sibling's edges --------------------------------------------------
    Array<RKRectBox>* sib = one(UXGeom.make((i16)50, (i16)60, (i16)40, (i16)20));
    UXRect near = UXGeom.make((i16)53, (i16)30, (i16)40, (i16)20);
    UXRect ss = RKGuides.snapMove(near, sib, parent, true, new Array());
    check("it left-aligns with a sibling", (i32)ss.x, (i32)50);

    // THE ORDERING TRAP: the right edge is 1px from a line and the left edge
    // 5px from another.  A first-match rule takes the left; the nearest must win.
    //   moving rect x=45 w=40  -> left 45, centre 65, right 85
    //   sibling    x=50 w=40  -> lines 50, 70, 90
    // left is 5 from 50; right is 5 from 90; centre is 5 from 70 — make the
    // right edge decisively nearer by nudging to x=49: right 89 is 1 from 90.
    UXRect trap = UXGeom.make((i16)49, (i16)30, (i16)40, (i16)20);
    UXRect ts = RKGuides.snapMove(trap, sib, parent, true, new Array());
    check("the NEAREST edge wins, not the first tested", (i32)ts.x, (i32)50);

    // ---- the magnet never yanks --------------------------------------------
    // Whatever it does, it must not move the rect further than the threshold.
    UXRect any = UXGeom.make((i16)44, (i16)44, (i16)30, (i16)10);
    UXRect as = RKGuides.snapMove(any, sib, parent, true, new Array());
    i32 moved = (i32)as.x - (i32)any.x;
    if (moved < (i32)0)
        {
        moved = -moved;
        }
    checkTrue("a snap never moves further than the threshold", moved <= (i32)RK_SNAP);

    // ---- resize snaps the SIZE, not the origin ------------------------------
    UXRect rr = UXGeom.make((i16)10, (i16)10, (i16)37, (i16)20); // right edge 47
    Array<RKRectBox>* rsib = one(UXGeom.make((i16)50, (i16)60, (i16)40, (i16)20));
    UXRect rs = RKGuides.snapResize(rr, rsib, parent, true, new Array());
    check("resizing leaves the origin fixed", (i32)rs.x, (i32)10);
    check("and stretches the width to the line", (i32)rs.w, (i32)40);

    // A resize can never turn the rect inside out, however far the pointer went.
    UXRect tiny = UXGeom.make((i16)10, (i16)10, (i16)1, (i16)1);
    UXRect ts2 = RKGuides.snapResize(tiny, none, parent, true, new Array());
    checkTrue("a resize never produces a negative size", ts2.w > (i16)0 && ts2.h > (i16)0);

    // ---- the guides reported are the ones actually used ---------------------
    Array<RKGuide>* g2 = new Array();
    RKGuides.snapMove(UXGeom.make((i16)2, (i16)20, (i16)40, (i16)20), none, parent, true, g2);
    check("only the axis that snapped reports a guide", (i32)g2.count(), (i32)1);
    checkTrue("and it is the vertical one", ((RKGuide* ?)g2.get((u16)0)).vertical);
    check("at the line it stuck to", ((RKGuide* ?)g2.get((u16)0)).pos, (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: snapping sticks to the nearest real line, and only when close\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
