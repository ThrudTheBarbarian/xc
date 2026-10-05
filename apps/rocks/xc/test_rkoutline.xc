// test_rkoutline.xc — the document structure behind the left-hand pane.
//
// The canvas shows one form; a .rsc holds several. This is what tells the
// designer the others exist, so the thing worth asserting is that EVERY tree
// appears and that the nesting under each one matches the model — an outline
// that quietly showed three of four trees would look perfectly normal.
//
// Pure data: no driver, no window. The data source takes a UXOutlineView* it
// never dereferences, so the tests pass null.
#import <Stdio.xc>
#import "UXRscModel.xc"
#import "RKOutline.xc"

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
bool sameStr(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && b[i] != (u8)0)
        {
        if (a[i] != b[i])
            {
            return false;
            }
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
void eq(u8* what, u8* got, u8* want)
    {
    if (sameStr(got, want))
        {
        Stdio.printf("  ok   %s = \"%s\"\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = \"%s\" (want \"%s\")\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;

    // Two trees, so "every tree appears" is actually testable — with one, a
    // broken loop and a correct one look identical.
    UXRscDoc* r = new UXRscDoc();

    UXRscTree* t0 = new UXRscTree();
    UXRscObject* r0 = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)200, (i32)100);
    UXRscObject* ok = UXRscObject.make((i32)UXR_T_BUTTON, (i32)10, (i32)10, (i32)60, (i32)20);
    ok.text = (u8*)"OK";
    UXRscObject* grp = UXRscObject.make((i32)UXR_T_IBOX, (i32)10, (i32)40, (i32)100, (i32)40);
    UXRscObject* in1 = UXRscObject.make((i32)UXR_T_RADIO, (i32)4, (i32)4, (i32)80, (i32)16);
    in1.text = (u8*)"Email";
    r0.addChild(ok);
    r0.addChild(grp);
    grp.addChild(in1);
    t0.root = r0;
    r.addTree(t0);

    UXRscTree* t1 = new UXRscTree();
    t1.kind = (i32)UXR_K_MENU;
    UXRscObject* r1 = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)200, (i32)20);
    t1.root = r1;
    r.addTree(t1);

    RKOutline* ol = new RKOutline();
    ol.build(r);

    // Top level is the trees — all of them.
    check("both trees are at the top level",
          ol.numberOfChildren((UXOutlineView*)0, (Object*)0), (i32)2);

    Object* tree0 = ol.childOfItem((UXOutlineView*)0, (Object*)0, (i32)0);
    Object* tree1 = ol.childOfItem((UXOutlineView*)0, (Object*)0, (i32)1);
    eq("first row names the dialog", ol.valueForItem((UXOutlineView*)0, tree0, (i32)0), (u8*)"dialog 0");
    eq("second row knows it is a menu", ol.valueForItem((UXOutlineView*)0, tree1, (i32)0), (u8*)"menu 1");

    // The ROOT box is the form itself, so its children hang off the tree row
    // rather than under a redundant "box" row — matching what the canvas does.
    check("the tree row holds the root's children, not the root",
          ol.numberOfChildren((UXOutlineView*)0, tree0), (i32)2);

    Object* rowOK = ol.childOfItem((UXOutlineView*)0, tree0, (i32)0);
    Object* rowGrp = ol.childOfItem((UXOutlineView*)0, tree0, (i32)1);
    eq("a titled object is labelled by its TEXT",
       ol.valueForItem((UXOutlineView*)0, rowOK, (i32)0), (u8*)"OK");
    eq("an untitled one falls back to its TYPE",
       ol.valueForItem((UXOutlineView*)0, rowGrp, (i32)0), (u8*)"ibox");

    // Nesting survives, and expandability follows it
    check("the group has one child", ol.numberOfChildren((UXOutlineView*)0, rowGrp), (i32)1);
    eq("and it is the radio",
       ol.valueForItem((UXOutlineView*)0,
                       ol.childOfItem((UXOutlineView*)0, rowGrp, (i32)0), (i32)0),
       (u8*)"Email");
    check("a leaf is not expandable",
          ol.isExpandable((UXOutlineView*)0, rowOK) ? (i32)1 : (i32)0, (i32)0);
    check("a group is", ol.isExpandable((UXOutlineView*)0, rowGrp) ? (i32)1 : (i32)0, (i32)1);
    check("an empty menu tree is not expandable",
          ol.isExpandable((UXOutlineView*)0, tree1) ? (i32)1 : (i32)0, (i32)0);

    // Rebuilding is the only update path, so it must be idempotent rather than
    // accumulating a second copy of the document.
    ol.build(r);
    check("rebuilding does not duplicate",
          ol.numberOfChildren((UXOutlineView*)0, (Object*)0), (i32)2);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the outline shows every tree and its nesting\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
