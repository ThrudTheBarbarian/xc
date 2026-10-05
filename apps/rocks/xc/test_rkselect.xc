// test_rkselect.xc — selection: outline row -> canvas.
//
// Drives the delegate the way a click does, by row index, because that is the
// path the real thing takes: the outline is a table underneath, selection
// arrives as a ROW, and the row has to be mapped back through the flattened
// visible order to the node it stands for.  Asserting against the model
// directly would skip exactly the step most likely to be wrong.
//
// Three behaviours: a FORM row switches which form the canvas shows; an OBJECT row
// selects within the current one; a placeholder (File's Owner, First Responder)
// is not on the canvas, and the Identity tab shows it.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXGeometry.xc"
#import "UXRscModel.xc"
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

// Two trees, so switching between them is testable at all.
UXRscDoc* sample(void)
    {
    UXRscDoc* r = new UXRscDoc();

    UXRscTree* t0 = new UXRscTree();
    UXRscObject* r0 = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)300, (i32)200);
    UXRscObject* ok = UXRscObject.make((i32)UXR_T_BUTTON, (i32)20, (i32)30, (i32)60, (i32)20);
    ok.text = (u8*)"OK";
    UXRscObject* nm = UXRscObject.make((i32)UXR_T_FIELD, (i32)20, (i32)60, (i32)120, (i32)22);
    r0.addChild(ok);
    r0.addChild(nm);
    t0.root = r0;
    r.addTree(t0);

    UXRscTree* t1 = new UXRscTree();
    UXRscObject* r1 = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)300, (i32)200);
    UXRscObject* go = UXRscObject.make((i32)UXR_T_BUTTON, (i32)10, (i32)10, (i32)50, (i32)20);
    go.text = (u8*)"Go";
    r1.addChild(go);
    t1.root = r1;
    r.addTree(t1);
    return r;
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
    win.open((u8*)"sel", UXGeom.make((i16)0, (i16)0, (i16)900, (i16)600), content);
    checkTrue("the window wires", RKMainBuilder.buildInto(content, c, (i16)900, (i16)600));

    UXRscDoc* r = sample();
    check("tree 0 realizes two widgets", c.showResource(r, (i32)0), (i32)2);
    win.tree.finalise();

    // The outline's visible rows, top level collapsed: the placeholders, then two form rows, as
    // Interface Builder lists them.
    c.formOutline.reloadData();
    check("File's Owner, First Responder and two forms are visible", (i32)c.formOutline.rowCount(), (i32)4);

    // File's Owner is not on the canvas: the Identity tab shows it.
    c.tableSelectionDidChange((UXTableView*)c.formOutline, (i32)0);
    check("File's Owner is selected", c.selKind, (i32)RKON_OWNER);
    check("the Identity tab is shown for it", c.shownTab(), (i32)0);
    checkTrue("which offers its class", c.identityCtl.classField != (UXTextField*)0);
    c.tableSelectionDidChange((UXTableView*)c.formOutline, (i32)1);
    check("First Responder is selected", c.selKind, (i32)RKON_FIRSTR);
    checkTrue("and has no class to set", c.identityCtl.classField == (UXTextField*)0);
    c.showTab((i32)1);

    // Selecting the SECOND form row switches the canvas.
    c.tableSelectionDidChange((UXTableView*)c.formOutline, (i32)3);
    check("selecting tree 1 switches the shown tree", c.shownTree, (i32)1);
    checkTrue("and drops the selection, which pointed into the old form",
              c.selectedObject() == (UXRscObject*)0);

    // Back to form 0, then open it so its objects get rows.
    c.tableSelectionDidChange((UXTableView*)c.formOutline, (i32)2);
    check("and back again", c.shownTree, (i32)0);

    // Expanding the form row exposes its objects; row 3 is then the button.
    c.formOutline.toggleRow((i32)2);
    check("expanding shows the form's two objects", (i32)c.formOutline.rowCount(), (i32)6);
    c.tableSelectionDidChange((UXTableView*)c.formOutline, (i32)3);
    checkTrue("an object row selects an object", c.selectedObject() != (UXRscObject*)0);
    check("and it is the one the row stood for",
          c.selectedObject().type, (i32)UXR_T_BUTTON);
    check("selecting an object does NOT switch trees", c.shownTree, (i32)0);

    // The overlay is placed over the widget, in canvas coordinates.
    checkTrue("a selection frame exists", c.selFrame != (RKSelectionFrame*)0);
    check("frame x tracks the widget", (i32)c.selFrame.frame().x, (i32)RK_FORM_X + (i32)20);
    check("frame y tracks the widget", (i32)c.selFrame.frame().y, (i32)RK_FORM_Y + (i32)30);
    check("frame w tracks the widget", (i32)c.selFrame.frame().w, (i32)60);

    // Selecting the OTHER object moves the same frame rather than making a second
    c.tableSelectionDidChange((UXTableView*)c.formOutline, (i32)4);
    check("the frame moved to the field", (i32)c.selFrame.frame().y, (i32)RK_FORM_Y + (i32)60);
    check("and the field is selected", c.selectedObject().type, (i32)UXR_T_FIELD);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: outline selection drives the canvas\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
