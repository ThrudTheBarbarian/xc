// test_rkwindow.xc — the editor's window, laid out as Interface Builder's: the inspector's tabs,
// the library (filtering it, placing a control where a press lands, adding an Object), the
// Identity tab (a control's class and name, an object's class, File's Owner's class), Delete and
// New Form -- each undoable.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXGeometry.xc"
#import "UXRscModel.xc"
#import "UXRscWrite.xc"
#import "UXRscRead.xc"
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
    if (a == (u8*)0 || b == (u8*)0)
        {
        return a == b;
        }
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
UXRscTree* shown(RKMainController* c)
    {
    return c.doc.treeAt(c.shownTree);
    }
void typeInto(UXTextField* f, u8* text, RKIdentity* id)
    {
    f.setText(text);
    id.onEdit(f);
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
    win.open((u8*)"Rocks", UXGeom.make((i16)0, (i16)0, (i16)1000, (i16)680), content);
    RKMainController* c = new RKMainController();
    checkTrue("the window wires", RKMainBuilder.buildInto(content, c, (i16)1000, (i16)680));

    UXRscDoc* r = new UXRscDoc();
    UXRscTree* main = new UXRscTree();
    main.name = (u8*)"MAIN";
    main.root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)400, (i32)300);
    UXRscObject* ok = UXRscObject.make((i32)UXR_T_BUTTON, (i32)20, (i32)20, (i32)60, (i32)20);
    ok.text = (u8*)"OK";
    main.root.addChild(ok);
    UXRscObject* box = UXRscObject.make((i32)UXR_T_BOX, (i32)100, (i32)100, (i32)200, (i32)120);
    box.seedPayload();
    main.root.addChild(box);
    r.addTree(main);
    c.showResource(r, (i32)0);
    win.tree.finalise();

    Stdio.printf("-- the inspector's tabs\n");
    check("four tab panes", (i32)c.tabPanes.count(), (i32)4);
    check("Attributes is shown first", c.shownTab(), (i32)1);
    c.inspectorTabs.applyNativeSelection((i32)2);
    c.onInspectorTab((UXControl*)c.inspectorTabs);
    checkTrue("choosing Size shows its pane", !((UXView* ?)c.tabPanes.get((u32)2)).isHidden());
    checkTrue("and hides Attributes", ((UXView* ?)c.tabPanes.get((u32)1)).isHidden());
    c.selectObject(ok);
    checkTrue("Size has the frame", c.sizeCtl.rowNamed((u8*)"X") != (RKRow*)0);
    checkTrue("Attributes has the rest", c.inspectorCtl.rowNamed((u8*)"Default") != (RKRow*)0 && c.inspectorCtl.rowNamed((u8*)"X") == (RKRow*)0);

    Stdio.printf("-- the library\n");
    check("every item is listed", c.library.count(), (i32)18);
    c.librarySearch.setText((u8*)"FIELD");
    c.onLibrarySearch(c.librarySearch);
    check("a filter narrows it, ignoring case", c.library.count(), (i32)1);
    checkTrue("to the text field", streq(c.library.itemAt((i32)0).name, (u8*)"Text Field"));
    c.librarySearch.setText((u8*)"");
    c.onLibrarySearch(c.librarySearch);
    c.libraryPick(c.library.named((u8*)"Button"));
    checkTrue("picking a control arms the canvas", c.placing != (RKLibraryItem*)0);
    checkTrue("and says what to do", streq(c.statusLabel.text(), (u8*)"Click in the form to place a Button"));
    i32 before = main.root.childCount();
    checkTrue("the next press places it", c.overlay.placeAt != (callback bool(i32 cx, i32 cy))0 && c.placeAt((i32)30, (i32)60));
    check("one more control in the form", shown(c).root.childCount(), before + (i32)1);
    UXRscObject* added = c.selectedObject();
    checkTrue("it is selected", added != (UXRscObject*)0 && added.type == (i32)UXR_T_BUTTON);
    check("where the press landed", added.x * (i32)1000 + added.y, (i32)30060);
    checkTrue("titled as the library says", streq(added.text, (u8*)"Button"));
    checkTrue("on the canvas", c.canvasMap.viewFor(added) != (UXView*)0);
    checkTrue("the press was taken: nothing is armed now", c.placing == (RKLibraryItem*)0);
    checkTrue("a press with nothing armed is not taken", !c.placeAt((i32)5, (i32)5));
    c.onUndo((UXMenuItem*)0);
    check("undo takes it away", shown(c).root.childCount(), before);

    c.libraryPick(c.library.named((u8*)"Checkbox"));
    c.placeAt((i32)120, (i32)130);
    UXRscObject* cb = c.selectedObject();
    UXRscObject* sbox = shown(c).root.childAt((i32)1);
    checkTrue("a control placed in a box goes in the box", shown(c).parentOf(cb) == sbox);
    check("at the box's coordinates", cb.x * (i32)1000 + cb.y, (i32)20030);

    Stdio.printf("-- a UXKit control GEM has no type for\n");
    c.libraryPick(c.library.named((u8*)"Slider"));
    c.placeAt((i32)30, (i32)250);
    UXRscObject* sl = c.selectedObject();
    checkTrue("a slider is a G_USERDEF", sl != (UXRscObject*)0 && sl.type == (i32)UXR_T_USERDEF);
    checkTrue("of class UXSlider", streq(c.doc.classOf(shown(c), sl), (u8*)"UXSlider"));
    checkTrue("with its starting value", streq(c.doc.attrOf(shown(c), sl, (u8*)"value"), (u8*)"50"));
    UXSlider* sw2 = (UXSlider* ?)c.canvasMap.viewFor(sl);
    checkTrue("the canvas shows a real slider", sw2 != (UXSlider*)0 && sw2.intValue() == (i32)50);
    RKRow* mx = c.inspectorCtl.rowNamed((u8*)"max");
    checkTrue("Attributes offers its range", mx != (RKRow*)0 && streq(mx.field.text(), (u8*)"100"));
    mx.field.setText((u8*)"40");
    c.inspectorCtl.onField(mx.field);
    checkTrue("an edit sets the attribute", streq(c.doc.attrOf(shown(c), sl, (u8*)"max"), (u8*)"40"));
    UXSlider* sw3 = (UXSlider* ?)c.canvasMap.viewFor(sl);
    checkTrue("and the slider follows", sw3 != (UXSlider*)0 && sw3.nativeMax() == (i32)40);
    c.onUndo((UXMenuItem*)0);
    checkTrue("undo puts the range back", streq(c.doc.attrOf(shown(c), shown(c).root.childAt(shown(c).root.childCount() - (i32)1), (u8*)"max"), (u8*)"100"));
    c.onUndo((UXMenuItem*)0);

    Stdio.printf("-- an Object\n");
    c.libraryPick(c.library.named((u8*)"Object"));
    check("the document has an object", (i32)c.doc.topObjects.count(), (i32)1);
    check("it is selected", c.selKind, (i32)RKON_OBJECT);
    check("the Identity tab is shown, to give it a class", c.shownTab(), (i32)0);
    typeInto(c.identityCtl.classField, (u8*)"LibraryController", c.identityCtl);
    checkTrue("its class", streq(c.doc.topObjectById((i32)1).cls, (u8*)"LibraryController"));
    RKOutlineNode* row = (RKOutlineNode* ?)c.outlineModel.roots.get((u32)2);
    checkTrue("the outline names it by its class", streq(row.label, (u8*)"LibraryController"));
    typeInto(c.identityCtl.nameField, (u8*)"Library", c.identityCtl);
    row = (RKOutlineNode* ?)c.outlineModel.roots.get((u32)2);
    checkTrue("then by its label", streq(row.label, (u8*)"Library"));
    c.onUndo((UXMenuItem*)0);
    checkTrue("undo takes the label back", c.doc.topObjectById((i32)1).label[0] == (u8)0);

    Stdio.printf("-- a control's class and name\n");
    UXRscObject* okNow = shown(c).root.childAt((i32)0);
    c.selectObject(okNow);
    checkTrue("the Identity tab offers its class", c.identityCtl.classField != (UXTextField*)0);
    typeInto(c.identityCtl.classField, (u8*)"FancyButton", c.identityCtl);
    checkTrue("the class is set", streq(c.doc.classOf(shown(c), okNow), (u8*)"FancyButton"));
    checkTrue("which gave it a logical id", okNow.logicalId != (i32)0);
    typeInto(c.identityCtl.nameField, (u8*)"okButton", c.identityCtl);
    checkTrue("and a name", streq(okNow.name, (u8*)"okButton"));
    c.onUndo((UXMenuItem*)0);
    c.onUndo((UXMenuItem*)0);
    checkTrue("undo takes both back", c.doc.classOf(shown(c), shown(c).root.childAt((i32)0)) == (u8*)0);

    Stdio.printf("-- File's Owner\n");
    c.tableSelectionDidChange((UXTableView*)c.formOutline, (i32)0);
    check("selected from the outline", c.selKind, (i32)RKON_OWNER);
    typeInto(c.identityCtl.classField, (u8*)"DocumentController", c.identityCtl);
    checkTrue("its class", streq(c.doc.ownerClass, (u8*)"DocumentController"));

    Stdio.printf("-- declaring a class Rocks cannot see\n");
    c.libraryPick(c.library.named((u8*)"Object"));
    typeInto(c.identityCtl.classField, (u8*)"Mixer", c.identityCtl);
    c.identityCtl.reshow();
    checkTrue("it says the class is not found", c.identityCtl.classInfo != (UXLabel*)0 && c.identityCtl.outletName != (UXTextField*)0);
    c.identityCtl.outletName.setText((u8*)"volume");
    c.identityCtl.outletType.setText((u8*)"UXSlider*");
    c.identityCtl.onAddOutlet((UXControl*)0);
    c.identityCtl.actionName.setText((u8*)"onMute");
    c.identityCtl.onAddAction((UXControl*)0);
    RKClass* mx = c.classBook.find((u8*)"Mixer");
    checkTrue("the class is declared", mx != (RKClass*)0 && mx.origin == (i32)RKC_DECLARED);
    check("with an outlet and an action", (i32)mx.outlets.count() * (i32)10 + (i32)mx.actions.count(), (i32)11);
    checkTrue("of the type given", streq(((RKMember* ?)mx.outlets.get((u32)0)).type, (u8*)"UXSlider*"));
    Data* db = UXRscWriter.write(c.doc);
    UXRscDoc* dr = UXRscReader.read(db.bytes(), db.length());
    RKClassBook* nb = new RKClassBook();
    nb.loadFrom(dr);
    RKClass* mx2 = nb.find((u8*)"Mixer");
    checkTrue("the declaration is saved with the document", mx2 != (RKClass*)0 && streq(((RKMember* ?)mx2.actions.get((u32)0)).name, (u8*)"onMute"));
    c.onUndo((UXMenuItem*)0);
    RKClass* mx3 = c.classBook.find((u8*)"Mixer");
    check("undo takes the action back", mx3 != (RKClass*)0 ? (i32)mx3.actions.count() : (i32)-1, (i32)0);
    c.onUndo((UXMenuItem*)0);
    c.onUndo((UXMenuItem*)0);
    c.onUndo((UXMenuItem*)0);

    Stdio.printf("-- Delete\n");
    UXRscObject* victim = shown(c).root.childAt((i32)0);
    c.selectObject(victim);
    i32 n0 = shown(c).root.childCount();
    c.onDelete((UXControl*)0);
    check("deletes the selected control", shown(c).root.childCount(), n0 - (i32)1);
    checkTrue("and nothing is selected", c.selectedObject() == (UXRscObject*)0);
    c.onUndo((UXMenuItem*)0);
    check("undo puts it back", shown(c).root.childCount(), n0);
    c.selectPlaceholder((i32)RKON_OBJECT, (i32)1);
    c.onDelete((UXControl*)0);
    check("deletes the selected object", (i32)c.doc.topObjects.count(), (i32)0);
    c.selectObject((UXRscObject*)0);
    c.onDelete((UXControl*)0);
    checkTrue("with nothing selected, says so", streq(c.statusLabel.text(), (u8*)"Nothing to delete"));

    Stdio.printf("-- the form's panel\n");
    check("the panel is the form's size", c.backdrop.formW * (i32)1000 + c.backdrop.formH, (i32)400300);
    c.overlay.pressX = (i32)390;
    c.overlay.pressY = (i32)290;
    c.onPick((UXRscObject*)0);
    checkTrue("a click on its background selects the form", c.selectedObject() == shown(c).root);
    RKRow* fw = c.sizeCtl.rowNamed((u8*)"W");
    fw.field.setText((u8*)"500");
    c.sizeCtl.onField(fw.field);
    check("Size makes it wider", shown(c).root.w, (i32)500);
    check("and the panel follows", c.backdrop.formW, (i32)500);
    c.overlay.pressX = (i32)900;
    c.onPick((UXRscObject*)0);
    checkTrue("a click off the panel selects nothing", c.selectedObject() == (UXRscObject*)0);
    c.viewLayout((i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT);
    c.onNewLayout((UXControl*)0);
    checkTrue("switching layout leaves no selection frame behind", c.selFrame == (RKSelectionFrame*)0 || c.selFrame.isHidden());
    check("a new phone layout is a phone's size", shown(c).root.w * (i32)1000 + shown(c).root.h, (i32)360640);
    checkTrue("and says so", streq(c.backdrop.label, (u8*)"phone portrait · 360 × 640"));
    c.onUndo((UXMenuItem*)0);
    c.viewLayout((i32)UXR_V_DESKTOP, (i32)UXR_V_ORIENT_NONE);

    Stdio.printf("-- New Form\n");
    i32 t0 = c.doc.treeCount();
    c.onNewForm((UXControl*)0);
    check("a new form", c.doc.treeCount(), t0 + (i32)1);
    check("on the canvas", c.shownTree, t0);
    c.onUndo((UXMenuItem*)0);
    check("undo removes it", c.doc.treeCount(), t0);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the IB window -- tabs, library, Identity, Delete, New Form\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
