// test_rkdrop.xc — reparent on drop (RKTree.reparentByGeometry): what contains what follows what is
// on screen.  Model only, so it runs on every target.
#import <Stdio.xc>
#import "RKModel.xc"

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
    // a 300x200 form: a box at (100,50) 120x100, and a button outside it
    RKTree* t = new RKTree();
    t.root = RKObject.make((i32)RKT_BOX, (i32)0, (i32)0, (i32)300, (i32)200);
    RKObject* box = RKObject.make((i32)RKT_BOX, (i32)100, (i32)50, (i32)120, (i32)100);
    RKObject* btn = RKObject.make((i32)RKT_BUTTON, (i32)10, (i32)10, (i32)40, (i32)20);
    t.root.addChild(box);
    t.root.addChild(btn);
    check((u8*)"an arrangement that already matches changes nothing", t.reparentByGeometry(), (i32)0);

    // dropped onto the box: it goes in, and stays where it was dropped
    btn.x = (i32)110;
    btn.y = (i32)60;
    check((u8*)"a button dropped onto a box changes parent", t.reparentByGeometry(), (i32)1);
    checkTrue("...into the box", t.parentOf(btn) == box);
    checkTrue("...at the same place on screen (box-relative 10,10)", btn.x == (i32)10 && btn.y == (i32)10);
    check((u8*)"...and the box has it", box.childCount(), (i32)1);
    check((u8*)"doing it again changes nothing", t.reparentByGeometry(), (i32)0);

    // moving the box carries the button (that is what being inside means); dragging it out releases it
    box.x = (i32)150;
    check((u8*)"moving the box keeps its contents", t.reparentByGeometry(), (i32)0);
    i32 bx = (i32)0;
    i32 by = (i32)0;
    t.absoluteOriginOf(btn, &bx, &by);
    checkTrue("...and they moved with it", bx == (i32)160 && by == (i32)60);
    btn.x = (i32)-120; // box-relative: back out to absolute (30,60)
    check((u8*)"a button dragged out of the box comes out", t.reparentByGeometry(), (i32)1);
    checkTrue("...to the form", t.parentOf(btn) == t.root);
    checkTrue("...where it was left", btn.x == (i32)30 && btn.y == (i32)60);

    // half in, half out: it is not enclosed, so it is not in
    btn.x = (i32)140;
    btn.y = (i32)60;
    check((u8*)"a button straddling the box's edge stays out", t.reparentByGeometry(), (i32)0);

    // a box dropped over buttons adopts them; the smallest enclosing container wins
    btn.x = (i32)160;
    btn.y = (i32)60;
    t.reparentByGeometry();
    RKObject* inner = RKObject.make((i32)RKT_IBOX, (i32)155, (i32)55, (i32)60, (i32)40);
    t.root.addChild(inner); // drawn on top, at the form's level
    check((u8*)"a box dropped over a button adopts it and is itself adopted", t.reparentByGeometry(), (i32)2);
    checkTrue("the button is in the SMALLEST box around it", t.parentOf(btn) == inner);
    checkTrue("which is inside the big box", t.parentOf(inner) == box);
    t.absoluteOriginOf(btn, &bx, &by);
    checkTrue("nothing moved on screen", bx == (i32)160 && by == (i32)60);

    // only containers parent: a button over a button does not swallow it
    RKObject* b2 = RKObject.make((i32)RKT_BUTTON, (i32)0, (i32)0, (i32)80, (i32)60);
    t.root.addChild(b2);
    RKObject* b3 = RKObject.make((i32)RKT_STRING, (i32)10, (i32)10, (i32)20, (i32)10);
    t.root.addChild(b3);
    t.reparentByGeometry();
    checkTrue("a button never contains a label", t.parentOf(b3) == t.root);

    // two boxes with the same rect: the earlier one parents, never both ways
    RKObject* twinA = RKObject.make((i32)RKT_BOX, (i32)0, (i32)120, (i32)50, (i32)50);
    RKObject* twinB = RKObject.make((i32)RKT_BOX, (i32)0, (i32)120, (i32)50, (i32)50);
    t.root.addChild(twinA);
    t.root.addChild(twinB);
    t.reparentByGeometry();
    checkTrue("twins: the later one goes in the earlier one", t.parentOf(twinB) == twinA && t.parentOf(twinA) == t.root);
    check((u8*)"...and stays put", t.reparentByGeometry(), (i32)0);

    // z-order: siblings keep their order
    RKTree* z = new RKTree();
    z.root = RKObject.make((i32)RKT_BOX, (i32)0, (i32)0, (i32)300, (i32)200);
    RKObject* first = RKObject.make((i32)RKT_BUTTON, (i32)110, (i32)10, (i32)20, (i32)20);
    RKObject* frame = RKObject.make((i32)RKT_BOX, (i32)100, (i32)0, (i32)100, (i32)100);
    RKObject* second = RKObject.make((i32)RKT_BUTTON, (i32)140, (i32)10, (i32)20, (i32)20);
    z.root.addChild(first);
    z.root.addChild(frame);
    z.root.addChild(second);
    z.reparentByGeometry();
    checkTrue("adopted siblings keep their front-to-back order",
              frame.childCount() == (i32)2 && frame.childAt((i32)0) == first && frame.childAt((i32)1) == second);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: reparent on drop -- in, out, adopt, smallest, ties, z-order\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
