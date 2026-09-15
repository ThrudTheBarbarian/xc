// test_rkinspector.xc — the inspector reflects the model, and edits write back.
//
// Two directions, and they are different claims:
//   selecting  -> the pane shows what the object IS
//   editing    -> the MODEL changes, and the canvas widget follows
//
// The second is the one that makes this an editor, and the one worth being
// strict about: it asserts the change landed in the RKObject, not merely that
// the field holds new text.  A pane that owned its own values would pass a
// weaker test and drift from the resource the moment anything else moved an
// object — which is exactly what canvas dragging will do next.
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
bool sameStr(u8* a, u8* b)
    {
    if (a == (u8*)0)
        {
        a = (u8*)"";
        }
    if (b == (u8*)0)
        {
        b = (u8*)"";
        }
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

    // number formatting both ways, before anything touches a widget
    check("parseInt", RKInspector.parseInt((u8*)"142"), (i32)142);
    check("parseInt negative", RKInspector.parseInt((u8*)"-7"), (i32)-7);
    check("parseInt junk is zero", RKInspector.parseInt((u8*)"abc"), (i32)0);
    eq("fmtInt", RKInspector.fmtInt((i32)205), (u8*)"205");
    eq("fmtInt negative", RKInspector.fmtInt((i32)-3), (u8*)"-3");
    eq("fmtInt zero", RKInspector.fmtInt((i32)0), (u8*)"0");

    RKMainController* c = new RKMainController();
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"insp", UXGeom.make((i16)0, (i16)0, (i16)900, (i16)600), content);
    checkTrue("the window wires", RKMainBuilder.buildInto(content, c, (i16)900, (i16)600));

    RKResource* r = new RKResource();
    RKTree* t = new RKTree();
    RKObject* root = RKObject.make((i32)RKT_BOX, (i32)0, (i32)0, (i32)300, (i32)200);
    RKObject* btn = RKObject.make((i32)RKT_BUTTON, (i32)20, (i32)30, (i32)60, (i32)20);
    RKObject* fld = RKObject.make((i32)RKT_FIELD, (i32)20, (i32)60, (i32)120, (i32)22);
    RKObject* chk = RKObject.make((i32)RKT_CHECKBOX, (i32)20, (i32)90, (i32)120, (i32)20);
    RKObject* rad = RKObject.make((i32)RKT_RADIO, (i32)20, (i32)120, (i32)120, (i32)20);
    btn.text = (u8*)"OK";
    root.addChild(btn);
    root.addChild(fld);
    root.addChild(chk);
    root.addChild(rad);
    t.root = root;
    r.addTree(t);
    c.showResource(r, (i32)0);
    win.tree.finalise();

    RKInspector* ins = c.inspectorCtl;

    // ---- the pane is PER TYPE ----------------------------------------------
    // The whole point of the schema: a button gets the properties a button
    // has, and a field is never offered one it cannot hold.
    c.selectObject(btn);
    eq("type is shown", ins.typeLabel.text(), (u8*)"button");
    checkTrue("a button offers Default", ins.rowNamed((u8*)"Default") != (RKRow*)0);
    checkTrue("a button offers Cancel", ins.rowNamed((u8*)"Cancel") != (RKRow*)0);
    checkTrue("a button offers Exit", ins.rowNamed((u8*)"Exit") != (RKRow*)0);
    checkTrue("a button is NOT offered Checked", ins.rowNamed((u8*)"Checked") == (RKRow*)0);
    checkTrue("a button is NOT offered Editable", ins.rowNamed((u8*)"Editable") == (RKRow*)0);
    checkTrue("geometry is universal", ins.rowNamed((u8*)"X") != (RKRow*)0);
    checkTrue("and Text, which a button has", ins.rowNamed((u8*)"Text") != (RKRow*)0);

    c.selectObject(fld);
    eq("switching selection re-renders", ins.typeLabel.text(), (u8*)"field");
    checkTrue("a field offers Editable", ins.rowNamed((u8*)"Editable") != (RKRow*)0);
    checkTrue("a field is NOT offered Checked", ins.rowNamed((u8*)"Checked") == (RKRow*)0);
    checkTrue("a field is NOT offered Default", ins.rowNamed((u8*)"Default") == (RKRow*)0);

    c.selectObject(chk);
    checkTrue("a checkbox IS offered Checked", ins.rowNamed((u8*)"Checked") != (RKRow*)0);
    checkTrue("but not Default", ins.rowNamed((u8*)"Default") == (RKRow*)0);

    c.selectObject(rad);
    checkTrue("a radio offers its group flag", ins.rowNamed((u8*)"Radio group") != (RKRow*)0);

    // ---- editing writes back to the MODEL ----------------------------------
    c.selectObject(btn);
    RKRow* rx = ins.rowNamed((u8*)"X");
    rx.field.setText((u8*)"120");
    ins.onField(rx.field);
    check("editing X moves the OBJECT", btn.x, (i32)120);

    RKRow* rt = ins.rowNamed((u8*)"Text");
    rt.field.setText((u8*)"Apply");
    ins.onField(rt.field);
    eq("editing Text changes the OBJECT", btn.text, (u8*)"Apply");
    checkTrue("the model does NOT alias the field buffer", btn.text != rt.field.text());

    // Editing must NOT rebuild the pane: a rebuild destroys the widget being
    // typed into and takes the keyboard focus with it.  Holding a row across
    // an edit is exactly what a designer's cursor does.
    checkTrue("the row survives an edit (the pane was not rebuilt)",
              ins.rowNamed((u8*)"X") == rx);

    // ---- a type-specific FLAG round-trips ----------------------------------
    RKRow* rd = ins.rowNamed((u8*)"Default");
    rd.box.setChecked(true);
    ins.onToggle((UXControl*)rd.box);
    checkTrue("ticking Default sets the flag BIT",
              (btn.flags & (i32)RKF_DEFAULT) != (i32)0);
    rd.box.setChecked(false);
    ins.onToggle((UXControl*)rd.box);
    checkTrue("and unticking clears it", (btn.flags & (i32)RKF_DEFAULT) == (i32)0);

    // state and flags are DIFFERENT words — a schema bug that confused them
    // would be invisible until the file round-tripped
    RKRow* rdis = ins.rowNamed((u8*)"Disabled");
    rdis.box.setChecked(true);
    ins.onToggle((UXControl*)rdis.box);
    checkTrue("Disabled lands in ob_state", (btn.state & (i32)RKS_DISABLED) != (i32)0);
    checkTrue("and NOT in ob_flags", (btn.flags & (i32)RKS_DISABLED) == (i32)0 || (i32)RKS_DISABLED != (i32)RKF_EDITABLE);

    // ---- Hidden actually hides ----------------------------------------------
    // The flag was being written to the model and then ignored: the canvas
    // applied DISABLED but never HIDETREE, so ticking Hidden changed the
    // resource and nothing on screen.
    UXView* bw = c.canvasMap.viewFor(btn);
    checkTrue("the button starts visible", !bw.isHidden());
    RKRow* rh = ins.rowNamed((u8*)"Hidden");
    checkTrue("Hidden is offered", rh != (RKRow*)0);
    rh.box.setChecked(true);
    ins.onToggle((UXControl*)rh.box);
    checkTrue("the flag reaches the model", (btn.flags & (i32)RKF_HIDETREE) != (i32)0);
    checkTrue("AND the widget is hidden on the canvas", bw.isHidden());
    rh.box.setChecked(false);
    ins.onToggle((UXControl*)rh.box);
    checkTrue("unticking brings it back", !bw.isHidden());

    // A form realized from scratch must honour it too, not only an edit — a
    // file whose objects are already hidden should open that way.  Realized
    // into a FRESH canvas rather than via showResource, which caches a pane
    // per tree and so shows the existing widgets rather than rebuilding them.
    // (That caching means an externally-changed model does not refresh the
    // canvas; not a problem while every edit goes through the inspector, and
    // worth revisiting when loading a second document lands.)
    btn.flags = btn.flags | (i32)RKF_HIDETREE;
    UXView* fresh = new UXView();
    content.addSubview(fresh, UXGeom.make((i16)0, (i16)0, (i16)300, (i16)200));
    RKCanvas* cv2 = new RKCanvas();
    cv2.realize(t, fresh);
    checkTrue("a form realized from scratch honours HIDETREE",
              cv2.viewFor(btn).isHidden());
    checkTrue("and its unhidden siblings are not", !cv2.viewFor(fld).isHidden());
    btn.flags = btn.flags & ~(i32)RKF_HIDETREE;

    // ---- a TOGGLE state reaches the real control ----------------------------
    // "Selected" on a radio wrote the model and stopped there: the code that
    // BUILT a form knew how to show it and the code that EDITED one did not, so
    // the tick moved and the radio on the canvas never did.  Same shape as the
    // Hidden bug before it, which is why both now go through one applyState.
    //
    // Asserted against the NATIVE control, not the peer's field: "we set the
    // flag" and "the control changed" are different claims, and only the second
    // one is what the designer sees.
    UXView* rw = c.canvasMap.viewFor(rad);
    c.selectObject(rad);
    RKRow* rsel = ins.rowNamed((u8*)"Selected");
    checkTrue("a radio offers Selected", rsel != (RKRow*)0);
    rsel.box.setChecked(true);
    ins.onToggle((UXControl*)rsel.box);
    checkTrue("the state bit reaches the model", (rad.state & (i32)RKS_SELECTED) != (i32)0);
    checkTrue("the widget agrees", ((UXRadioButton* ?)rw).isSelected());
    win.displayAll();
    check("and the NATIVE radio is on",
          d.controlChecked(win.tree.structHandle, (i32)rw.index), (i32)1);
    rsel.box.setChecked(false);
    ins.onToggle((UXControl*)rsel.box);
    win.displayAll();
    checkTrue("unticking clears the model", (rad.state & (i32)RKS_SELECTED) == (i32)0);
    check("and turns the NATIVE radio off",
          d.controlChecked(win.tree.structHandle, (i32)rw.index), (i32)0);

    // A checkbox is the same mechanism through a different state bit, and a
    // schema that confused the two would look right on one and wrong on the other.
    UXView* cw = c.canvasMap.viewFor(chk);
    c.selectObject(chk);
    RKRow* rchk = ins.rowNamed((u8*)"Checked");
    rchk.box.setChecked(true);
    ins.onToggle((UXControl*)rchk.box);
    win.displayAll();
    checkTrue("Checked reaches the model", (chk.state & (i32)RKS_CHECKED) != (i32)0);
    check("and the NATIVE check box is on",
          d.controlChecked(win.tree.structHandle, (i32)cw.index), (i32)1);

    // A form opened from disk must show it too, not only one that was edited.
    rad.state = rad.state | (i32)RKS_SELECTED;
    UXView* fresh2 = new UXView();
    content.addSubview(fresh2, UXGeom.make((i16)0, (i16)220, (i16)300, (i16)200));
    RKCanvas* cv3 = new RKCanvas();
    cv3.realize(t, fresh2);
    checkTrue("a form realized from scratch shows a selected radio",
              ((UXRadioButton* ?)cv3.viewFor(rad)).isSelected());
    rad.state = rad.state & ~(i32)RKS_SELECTED;

    // TWO radios, both selected in the model.  AppKit auto-groups radio buttons
    // that share a superview and action -- and every control the driver
    // realizes is a flat child of the ONE content view, so the whole window
    // risks becoming a single radio group regardless of what the resource says.
    // On a design surface that would mean ticking Selected on one radio
    // silently un-ticking an unrelated one somewhere else in the form.
    RKObject* rad2 = RKObject.make((i32)RKT_RADIO, (i32)20, (i32)150, (i32)120, (i32)20);
    root.addChild(rad2);
    rad.state = rad.state | (i32)RKS_SELECTED;
    rad2.state = rad2.state | (i32)RKS_SELECTED;
    UXView* two = new UXView();
    content.addSubview(two, UXGeom.make((i16)320, (i16)0, (i16)300, (i16)200));
    RKCanvas* cv4 = new RKCanvas();
    cv4.realize(t, two);
    win.tree.finalise();
    win.displayAll();
    check("two radios selected in the model: the first shows selected",
          d.controlChecked(win.tree.structHandle, (i32)cv4.viewFor(rad).index), (i32)1);
    check("and so does the second",
          d.controlChecked(win.tree.structHandle, (i32)cv4.viewFor(rad2).index), (i32)1);
    rad.state = rad.state & ~(i32)RKS_SELECTED;
    rad2.state = rad2.state & ~(i32)RKS_SELECTED;

    // ---- text alignment ------------------------------------------------------
    // What makes a column of "Name:" "Size:" "Kind:" line its colons up: right
    // align the text, then align the boxes' right edges with the snap guides.
    // Left-aligned text cannot be lined up however carefully the boxes are
    // placed, because the colon lands wherever the word before it ends.
    RKObject* txt = RKObject.make((i32)RKT_TEXT, (i32)20, (i32)150, (i32)120, (i32)20);
    txt.ted = new RKTedinfo();
    txt.ted.text = (u8*)"Name:";
    root.addChild(txt);
    UXView* tpane = new UXView();
    content.addSubview(tpane, UXGeom.make((i16)640, (i16)0, (i16)300, (i16)260));
    RKCanvas* cv5 = new RKCanvas();
    cv5.realize(t, tpane);
    win.tree.finalise();
    win.displayAll();

    // Only the TEDINFO-bearing types have a te_just to align; a plain G_STRING
    // has no TEDINFO, so offering it there would be a control that does nothing.
    c.selectObject(txt);
    RKRow* ral = ins.rowNamed((u8*)"Alignment");
    checkTrue("a text object offers Alignment", ral != (RKRow*)0);
    checkTrue("rendered as a pop-up, not a field", ral.pop != (UXPopUpButton*)0);
    check("with three choices", ral.pop.count(), (i32)3);
    c.selectObject(btn);
    checkTrue("a plain button is NOT offered Alignment (it has no TEDINFO)",
              ins.rowNamed((u8*)"Alignment") == (RKRow*)0);

    // A FIELD is the type the feature was asked for, and a second copy of the
    // TEDINFO list here once omitted it -- so the row silently never appeared.
    c.selectObject(fld);
    checkTrue("a text field IS offered Alignment", ins.rowNamed((u8*)"Alignment") != (RKRow*)0);

    // A G_STRING is what a designer labels a text box with, so it is where
    // alignment is wanted most -- and it has no TEDINFO to put it in.  Choosing
    // a non-left alignment promotes it to G_TEXT, which is the format's own
    // answer and round-trips through a plain .rsc.
    RKObject* str = RKObject.make((i32)RKT_STRING, (i32)20, (i32)180, (i32)90, (i32)20);
    str.text = (u8*)"Name:";
    root.addChild(str);
    c.selectObject(str);
    RKRow* rs = ins.rowNamed((u8*)"Alignment");
    checkTrue("a string IS offered Alignment", rs != (RKRow*)0);
    check("and it starts left", rs.pop.selectedIndex(), (i32)0);
    checkTrue("while it is still a plain string", str.ted == (RKTedinfo*)0);
    rs.pop.selectItem((i32)1); // Right
    ins.onEnum((UXControl*)rs.pop);
    check("aligning it promotes it to G_TEXT", str.type, (i32)RKT_TEXT);
    checkTrue("which gives it the TEDINFO the format keeps te_just in",
              str.ted != (RKTedinfo*)0);
    check("carrying the alignment", str.ted.just, (i32)1);
    eq("and keeping its text", str.ted.text, (u8*)"Name:");
    eq("the pane re-rendered for the new type", ins.typeLabel.text(), (u8*)"text");

    // Picking "Right" must reach the model AND the widget AND the real control.
    c.selectObject(txt);
    ral = ins.rowNamed((u8*)"Alignment");
    ral.pop.selectItem((i32)1); // index 1 = "Right"
    ins.onEnum((UXControl*)ral.pop);
    check("choosing Right stores GEM's te_just (1 = right)", txt.ted.just, (i32)1);
    UXView* tw = cv5.viewFor(txt);
    RKCanvas.applyState(tw, txt);
    // These two numberings used to disagree -- te_just was 0/1/2 = left/right/
    // centre while UX_ALIGN_* was left/centre/right -- so passing one through as
    // the other silently swapped right and centre.  UX_ALIGN_* is now numbered
    // to match the format, which deletes the conversion rather than documenting
    // it: no mapping cannot be got wrong.
    check("and the WIDGET is right-aligned, not centred",
          ((UXControl* ?)tw).alignment(), (i32)UX_ALIGN_RIGHT);
    win.displayAll();
    // UX_ALIGN_* is numbered to MATCH te_just, so the native read-back is
    // simply the model's own value -- no conversion to get backwards.
    check("and so is the NATIVE control",
          d.controlAlign(win.tree.structHandle, (i32)tw.index), txt.ted.just);

    ral.pop.selectItem((i32)2); // "Centre"
    ins.onEnum((UXControl*)ral.pop);
    check("choosing Centre stores te_just 2", txt.ted.just, (i32)2);
    RKCanvas.applyState(tw, txt);
    check("and the widget is CENTRED, not right", ((UXControl* ?)tw).alignment(), (i32)UX_ALIGN_CENTER);
    win.displayAll();
    check("native agrees", d.controlAlign(win.tree.structHandle, (i32)tw.index), txt.ted.just);

    // A resource opened from disk must show its alignment too, not only one
    // just edited.
    txt.ted.just = (i32)1;
    UXView* fresh3 = new UXView();
    content.addSubview(fresh3, UXGeom.make((i16)640, (i16)270, (i16)300, (i16)260));
    RKCanvas* cv6 = new RKCanvas();
    cv6.realize(t, fresh3);
    check("a form realized from scratch honours te_just",
          ((UXControl* ?)cv6.viewFor(txt)).alignment(), (i32)UX_ALIGN_RIGHT);

    // ---- the canvas follows -------------------------------------------------
    UXView* w = c.canvasMap.viewFor(btn);
    checkTrue("the widget is findable", w != (UXView*)0);
    check("the widget moved with the model", (i32)w.frame().x, (i32)120);

    // ---- the loading guard --------------------------------------------------
    btn.x = (i32)7;
    c.selectObject(btn);
    check("show() does not write back through its own hooks", btn.x, (i32)7);

    // ---- nothing selected ---------------------------------------------------
    ins.show((RKObject*)0);
    eq("clearing blanks the type", ins.typeLabel.text(), (u8*)"—");
    check("and removes every row", ins.rowCount(), (i32)0);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the inspector is per-type, and edits write back to the model\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
