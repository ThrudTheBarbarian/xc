// test_rkundo.xc — undo and redo in the real editor: a drag, typing into the inspector (one step
// for the whole word), a toggle, and New Layout, each undone and redone in turn.  Steps are
// snapshots of the document, so an undone state is a new set of objects: the checks look the
// objects up again each time rather than holding on to them.
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
    check(what, got ? (i32)1 : (i32)0, (i32)1);
    }
bool streq(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
// the button, in whatever document the editor has now
UXRscObject* button(RKMainController* c)
    {
    return c.doc.treeAt((i32)0).root.childAt((i32)0);
    }
void type(RKMainController* c, u8* row, u8* text)
    {
    RKRow* r = c.inspectorCtl.rowNamed(row);
    r.field.setText(text);
    c.inspectorCtl.onField(r.field);
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
    UXWindow* win = new UXWindow();
    UXView* content = new UXView();
    win.open((u8*)"Rocks", UXGeom.make((i16)0, (i16)0, (i16)900, (i16)600), content);
    RKMainController* c = new RKMainController();
    checkTrue("the window wires", RKMainBuilder.buildInto(content, c, (i16)900, (i16)600));

    UXRscDoc* r = new UXRscDoc();
    UXRscTree* main = new UXRscTree();
    main.name = (u8*)"MAIN";
    main.root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)300, (i32)200);
    UXRscObject* ok = UXRscObject.make((i32)UXR_T_BUTTON, (i32)20, (i32)30, (i32)60, (i32)20);
    ok.text = (u8*)"OK";
    main.root.addChild(ok);
    r.addTree(main);
    c.showResource(r, (i32)0);
    win.tree.finalise();
    checkTrue("nothing to undo at first", !c.history.canUndo());

    Stdio.printf("-- a drag\n");
    UXRscObject* btn = button(c);
    c.onPick(btn);
    c.overlay.setSelection(btn);
    c.overlay.drag.snapOn = false;
    c.overlay.drag.begin(main.root, btn, (i32)30, (i32)35);
    c.overlay.drag.step((i32)130, (i32)85);
    c.onDragStep(btn);
    c.overlay.drag.step((i32)140, (i32)95);
    c.onDragStep(btn);
    c.overlay.drag.end();
    c.onDragEnd(btn);
    check("it moved", button(c).x, (i32)130);
    c.onUndo((UXMenuItem*)0);
    check("undo puts it back, all the way", button(c).x, (i32)20);
    checkTrue("the canvas shows the undone document", c.canvasMap.viewFor(button(c)) != (UXView*)0);
    check("its widget is back too", (i32)c.canvasMap.viewFor(button(c)).frame().x, (i32)20);
    checkTrue("the button is still selected", c.selected == button(c));
    c.onRedo((UXMenuItem*)0);
    check("redo moves it again", button(c).x, (i32)130);
    c.onUndo((UXMenuItem*)0);

    Stdio.printf("-- a click that does not move is not a step\n");
    btn = button(c);
    c.onPick(btn);
    c.onDragEnd(btn);
    checkTrue("only the drag's step is there to redo", c.history.canRedo());

    Stdio.printf("-- typing\n");
    c.selectObject(button(c));
    type(c, (u8*)"Text", (u8*)"A");
    type(c, (u8*)"Text", (u8*)"Ap");
    type(c, (u8*)"Text", (u8*)"Apply");
    checkTrue("typed", streq(button(c).text, (u8*)"Apply"));
    checkTrue("a new edit empties redo", !c.history.canRedo());
    c.onUndo((UXMenuItem*)0);
    checkTrue("one undo takes the whole word back", streq(button(c).text, (u8*)"OK"));
    checkTrue("and the inspector shows the old text", streq(c.inspectorCtl.rowNamed((u8*)"Text").field.text(), (u8*)"OK"));
    c.onRedo((UXMenuItem*)0);
    checkTrue("redo types it again", streq(button(c).text, (u8*)"Apply"));

    Stdio.printf("-- typing into another field is another step\n");
    type(c, (u8*)"X", (u8*)"44");
    check("moved by its X", button(c).x, (i32)44);
    c.onUndo((UXMenuItem*)0);
    check("undo takes back the X", button(c).x, (i32)20);
    checkTrue("but not the text", streq(button(c).text, (u8*)"Apply"));

    Stdio.printf("-- a toggle\n");
    RKRow* dis = c.inspectorCtl.rowNamed((u8*)"Disabled");
    dis.box.setChecked(true);
    c.inspectorCtl.onToggle((UXControl*)dis.box);
    checkTrue("disabled", (button(c).state & (i32)UXR_S_DISABLED) != (i32)0);
    c.onUndo((UXMenuItem*)0);
    checkTrue("undo enables it", (button(c).state & (i32)UXR_S_DISABLED) == (i32)0);

    Stdio.printf("-- New Layout\n");
    c.viewLayout((i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT);
    c.onNewLayout((UXControl*)0);
    check("a phone layout", c.doc.treeCount(), (i32)2);
    check("on the canvas", c.shownTree, (i32)1);
    c.onUndo((UXMenuItem*)0);
    check("undo removes it", c.doc.treeCount(), (i32)1);
    check("and shows the desktop tree", c.shownTree, (i32)0);
    check("the form is gone with it", c.doc.formCount(), (i32)0);
    c.onRedo((UXMenuItem*)0);
    check("redo brings it back", c.doc.treeCount(), (i32)2);
    check("on the canvas", c.shownTree, (i32)1);
    c.onNewLayout((UXControl*)0);
    c.onUndo((UXMenuItem*)0);
    check("a refused New Layout left no step: undo removes the phone layout", c.doc.treeCount(), (i32)1);

    Stdio.printf("-- the end of the list\n");
    while (c.history.canUndo())
        {
        c.onUndo((UXMenuItem*)0);
        }
    c.onUndo((UXMenuItem*)0);
    checkTrue("undo with nothing left says so", streq(c.statusLabel.text(), (u8*)"Nothing to undo"));
    checkTrue("the first state is back", streq(button(c).text, (u8*)"OK") && button(c).x == (i32)20);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: undo and redo -- drag, typing, toggle, New Layout\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
