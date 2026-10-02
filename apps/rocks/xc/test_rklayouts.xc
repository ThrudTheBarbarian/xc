// test_rklayouts.xc — the layout selector: Desktop / Tablet / Phone, Rotate and New Layout.
//
// Driven through the TOOLBAR, as a click arrives: the item's tag is recorded as the toolbar's
// selection and the one action fires.  What it pins down is UXNB-V2's editor contract: a form
// factor with no layout reads "no layout -- create one" and the canvas does NOT fall back to
// another form factor's tree; New Layout seeds from what is on the canvas; Rotate moves between a
// device's portrait and landscape layouts; the desktop has no orientation.
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

bool says(RKMainController* c, u8* want)
    {
    u8* got = c.statusLabel.text();
    i32 i = (i32)0;
    while (got[i] != (u8)0 && want[i] != (u8)0 && got[i] == want[i])
        {
        i = i + (i32)1;
        }
    if (got[i] != want[i])
        {
        Stdio.printf("    status is \"%s\"\n", got);
        return false;
        }
    return true;
    }
void click(RKMainController* c, i32 tag)
    {
    c.toolbar.applyNativeItemClick(tag);
    c.onToolbar((UXControl*)c.toolbar);
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
    win.open((u8*)"layouts", UXGeom.make((i16)0, (i16)0, (i16)900, (i16)600), content);
    checkTrue("the window wires, toolbar included", RKMainBuilder.buildInto(content, c, (i16)900, (i16)600));
    checkTrue("the controller has its toolbar", c.toolbar != (UXToolbar*)0);

    RKResource* r = new RKResource();
    RKTree* main = new RKTree();
    main.name = (u8*)"MAIN";
    main.root = RKObject.make((i32)RKT_BOX, (i32)0, (i32)0, (i32)300, (i32)200);
    RKObject* ok = RKObject.make((i32)RKT_BUTTON, (i32)20, (i32)30, (i32)60, (i32)20);
    ok.text = (u8*)"OK";
    main.root.addChild(ok);
    r.addTree(main);
    c.showResource(r, (i32)0);
    win.tree.finalise();

    click(c, (i32)RKTB_DESKTOP);
    checkTrue("a lone tree is its desktop layout", says(c, (u8*)"desktop layout"));
    click(c, (i32)RKTB_ROTATE);
    checkTrue("the desktop has no orientation", says(c, (u8*)"The desktop has no orientation"));

    click(c, (i32)RKTB_PHONE);
    checkTrue("no phone layout: says so", says(c, (u8*)"No phone portrait layout -- New Layout creates one"));
    check((u8*)"...and the canvas does NOT show another form factor's tree instead", c.shownTree, (i32)0);

    click(c, (i32)RKTB_NEWLAYOUT);
    check((u8*)"New Layout adds a tree", r.treeCount(), (i32)2);
    check((u8*)"...and shows it", c.shownTree, (i32)1);
    checkTrue("...saying what it made", says(c, (u8*)"New phone portrait layout"));
    RKVariant* pv = r.formOf(main).variantFor(r.treeAt((i32)1));
    checkTrue("it is MAIN's phone-portrait layout", pv != (RKVariant*)0 && pv.klass == (i32)RKV_PHONE && pv.orient == (i32)RKV_ORIENT_PORTRAIT);
    check((u8*)"its widget is on the canvas", (i32)c.canvasMap.objs.count(), (i32)1);
    checkTrue("the document is dirty", c.dirty);
    click(c, (i32)RKTB_NEWLAYOUT);
    checkTrue("a second phone-portrait layout is refused", says(c, (u8*)"There is already a phone portrait layout"));
    check((u8*)"...and nothing was added", r.treeCount(), (i32)2);

    // The phone layout is moved about, then turned on its side.
    r.treeAt((i32)1).root.childAt((i32)0).x = (i32)5;
    click(c, (i32)RKTB_ROTATE);
    checkTrue("no landscape layout yet", says(c, (u8*)"No phone landscape layout -- New Layout creates one"));
    check((u8*)"...the portrait one stays up", c.shownTree, (i32)1);
    click(c, (i32)RKTB_NEWLAYOUT);
    check((u8*)"New Layout makes the landscape one", c.shownTree, (i32)2);
    check((u8*)"...seeded from the PORTRAIT layout on the canvas, not the desktop's",
          r.treeAt((i32)2).root.childAt((i32)0).x, (i32)5);
    click(c, (i32)RKTB_ROTATE);
    check((u8*)"Rotate goes back to portrait", c.shownTree, (i32)1);
    click(c, (i32)RKTB_ROTATE);
    check((u8*)"...and to landscape", c.shownTree, (i32)2);

    click(c, (i32)RKTB_DESKTOP);
    check((u8*)"Desktop shows MAIN again", c.shownTree, (i32)0);
    click(c, (i32)RKTB_TABLET);
    checkTrue("no tablet layout: says so", says(c, (u8*)"No tablet portrait layout -- New Layout creates one"));
    check((u8*)"...and stays on the desktop's", c.shownTree, (i32)0);
    click(c, (i32)RKTB_PHONE);
    check((u8*)"Phone (after the desktop) comes back in portrait", c.shownTree, (i32)1);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the layout selector -- per-form-factor layouts, rotate, new layout\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
