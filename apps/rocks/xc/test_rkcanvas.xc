// test_rkcanvas.xc — a resource model becomes REAL UXKit widgets.
//
// The claim being tested is the one the whole rewrite rests on: the canvas
// hosts the same widget objects the edited app will run, so there is no second
// renderer to drift.  That means asserting the model produced actual typed
// widgets — a button really is a UXButton, a field really is a UXTextField —
// not merely that something appeared.
//
// Built by hand rather than read from a file, so this runs without file I/O
// and stays honest about what it is testing: the MAPPING, not the parser.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "RKModel.xc"
#import "RKCanvas.xc"

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
    ux_ak_set_capture((i32)1); // native widgets, no window shown
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no AppKit boot\n");
        return;
        }

    // A form with one of each interesting type, nested one level deep so the
    // recursion is exercised rather than just the top row.
    RKTree* t = new RKTree();
    RKObject* root = RKObject.make((i32)RKT_BOX, (i32)0, (i32)0, (i32)300, (i32)200);
    RKObject* btn = RKObject.make((i32)RKT_BUTTON, (i32)10, (i32)10, (i32)80, (i32)24);
    RKObject* lbl = RKObject.make((i32)RKT_STRING, (i32)10, (i32)44, (i32)120, (i32)16);
    RKObject* fld = RKObject.make((i32)RKT_FIELD, (i32)10, (i32)70, (i32)160, (i32)22);
    RKObject* grp = RKObject.make((i32)RKT_IBOX, (i32)10, (i32)100, (i32)200, (i32)80);
    RKObject* chk = RKObject.make((i32)RKT_CHECKBOX, (i32)8, (i32)8, (i32)120, (i32)20);
    RKObject* rad = RKObject.make((i32)RKT_RADIO, (i32)8, (i32)34, (i32)120, (i32)20);
    btn.text = (u8*)"OK";
    lbl.text = (u8*)"Name:";
    chk.text = (u8*)"Hidden";
    rad.text = (u8*)"Email";
    chk.state = (i32)RKS_CHECKED;
    rad.state = (i32)RKS_SELECTED;
    fld.ted.text = (u8*)"typed";
    root.addChild(btn);
    root.addChild(lbl);
    root.addChild(fld);
    root.addChild(grp);
    grp.addChild(chk);
    grp.addChild(rad);
    t.root = root;

    UXView* canvas = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"canvas", UXGeom.make((i16)0, (i16)0, (i16)400, (i16)300), canvas);

    RKCanvas* cv = new RKCanvas();
    i32 n = cv.realize(t, canvas);
    // 4 direct children + 2 nested = 6.  The ROOT is not realized: it is the
    // form's background, and nesting a redundant container would shift every
    // child's coordinates by its origin.
    check("widgets realized (root excluded, nesting included)", n, (i32)6);

    // The mapping produced real, typed widgets — this is the claim that matters
    check("canvas took 4 direct children", (i32)canvas.subviews.count(), (i32)4);
    UXView* w0 = (UXView* ?)canvas.subviews.get((u16)0);
    UXView* w3 = (UXView* ?)canvas.subviews.get((u16)3);
    check("a GEM button became a UXKindButton", (i32)w0.kind(), (i32)UXKindButton);
    check("an IBOX became a plain view (no chrome)", (i32)w3.kind(), (i32)UXKindView);
    check("and holds its two nested widgets", (i32)w3.subviews.count(), (i32)2);
    check("a nested checkbox is a UXKindCheckbox",
          (i32)((UXView* ?)w3.subviews.get((u16)0)).kind(), (i32)UXKindCheckbox);
    check("a nested radio is a UXKindRadio",
          (i32)((UXView* ?)w3.subviews.get((u16)1)).kind(), (i32)UXKindRadio);

    // The object -> widget map selection depends on: every realized object
    // must be findable, and one that was never realized must not be.
    checkTrue("the map finds a realized object's widget", cv.viewFor(btn) == w0);
    checkTrue("and returns nothing for the unrealized root", cv.viewFor(root) == (UXView*)0);

    // Geometry survives: a GEM child's x/y are parent-relative and so are a
    // subview's, so the numbers should pass straight through untranslated.
    check("button x", (i32)w0.frame().x, (i32)10);
    check("button y", (i32)w0.frame().y, (i32)10);
    check("button w", (i32)w0.frame().w, (i32)80);

    win.tree.finalise();
    win.close();

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: a resource model realizes as real UXKit widgets\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
