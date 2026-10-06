// test_rkvary.xc — one control, several layouts: an edit to what the control says reaches every
// layout's copy; where it sits does not; and a property a layout VARIES keeps that layout's own
// value until it is shared again.  The variations are saved with the document and undone with
// everything else.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXGeometry.xc"
#import "UXRscModel.xc"
#import "UXRscRead.xc"
#import "UXRscWrite.xc"
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
// the button in layout `tree` of the editor's document
UXRscObject* okIn(RKMainController* c, i32 tree)
    {
    return c.doc.treeAt(tree).root.childAt((i32)0);
    }
void typeText(RKMainController* c, u8* text)
    {
    RKRow* r = c.inspectorCtl.rowNamed((u8*)"Text");
    r.field.setText(text);
    c.inspectorCtl.onField(r.field);
    }
void vary(RKMainController* c, u8* prop)
    {
    RKRow* r = c.inspectorCtl.rowNamed(prop);
    c.inspectorCtl.onVary((UXControl*)r.vary);
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
    win.open((u8*)"Rocks", UXGeom.make((i16)0, (i16)0, (i16)1100, (i16)700), content);
    RKMainController* c = new RKMainController();
    checkTrue("the window wires", RKMainBuilder.buildInto(content, c, (i16)1100, (i16)700));

    UXRscDoc* r = new UXRscDoc();
    UXRscTree* desk = new UXRscTree();
    desk.name = (u8*)"MAIN";
    desk.root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)300, (i32)200);
    UXRscObject* ok = UXRscObject.make((i32)UXR_T_BUTTON, (i32)20, (i32)30, (i32)60, (i32)20);
    ok.text = (u8*)"OK";
    desk.root.addChild(ok);
    UXRscObject* solo = UXRscObject.make((i32)UXR_T_BUTTON, (i32)100, (i32)30, (i32)60, (i32)20);
    solo.text = (u8*)"Solo";
    r.addTree(desk);
    r.addVariant(desk, (i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT);
    desk.root.addChild(solo); // after the phone was seeded: on the desktop only
    c.showResource(r, (i32)0);
    win.tree.finalise();

    Stdio.printf("-- shared by default\n");
    c.selectObject(okIn(c, (i32)0));
    checkTrue("a control in two layouts offers Vary", c.inspectorCtl.rowNamed((u8*)"Text").vary != (UXButton*)0);
    checkTrue("reading Vary, not Varies", streq(c.inspectorCtl.rowNamed((u8*)"Text").vary.title, (u8*)"Vary"));
    checkTrue("the frame has none: it is each layout's own", c.sizeCtl.rowNamed((u8*)"X").vary == (UXButton*)0);
    typeText(c, (u8*)"Done");
    checkTrue("the desktop says Done", streq(okIn(c, (i32)0).text, (u8*)"Done"));
    checkTrue("and so does the phone", streq(okIn(c, (i32)1).text, (u8*)"Done"));
    RKRow* dis = c.inspectorCtl.rowNamed((u8*)"Disabled");
    dis.box.setChecked(true);
    c.inspectorCtl.onToggle((UXControl*)dis.box);
    checkTrue("a toggle is shared too", (okIn(c, (i32)1).state & (i32)UXR_S_DISABLED) != (i32)0);
    dis = c.inspectorCtl.rowNamed((u8*)"Disabled");
    dis.box.setChecked(false);
    c.inspectorCtl.onToggle((UXControl*)dis.box);
    RKRow* rx = c.sizeCtl.rowNamed((u8*)"X");
    rx.field.setText((u8*)"77");
    c.sizeCtl.onField(rx.field);
    check("a move is this layout's", okIn(c, (i32)0).x, (i32)77);
    check("the phone's stays put", okIn(c, (i32)1).x, (i32)20);
    c.selectObject(c.doc.treeAt((i32)0).root.childAt((i32)1));
    checkTrue("a control in one layout offers no Vary", c.inspectorCtl.rowNamed((u8*)"Text").vary == (UXButton*)0);

    Stdio.printf("-- the phone varies its text\n");
    c.viewLayout((i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT);
    c.selectObject(okIn(c, (i32)1));
    vary(c, (u8*)"Text");
    checkTrue("the toggle reads Varies", streq(c.inspectorCtl.rowNamed((u8*)"Text").vary.title, (u8*)"Varies"));
    typeText(c, (u8*)"Go");
    checkTrue("the phone says Go", streq(okIn(c, (i32)1).text, (u8*)"Go"));
    checkTrue("the desktop still says Done", streq(okIn(c, (i32)0).text, (u8*)"Done"));
    c.viewLayout((i32)UXR_V_DESKTOP, (i32)UXR_V_ORIENT_NONE);
    c.selectObject(okIn(c, (i32)0));
    typeText(c, (u8*)"Finish");
    checkTrue("the desktop's edit does not reach a layout that varies it", streq(okIn(c, (i32)1).text, (u8*)"Go"));
    RKRow* dis2 = c.inspectorCtl.rowNamed((u8*)"Disabled");
    dis2.box.setChecked(true);
    c.inspectorCtl.onToggle((UXControl*)dis2.box);
    checkTrue("but what it does not vary still follows", (okIn(c, (i32)1).state & (i32)UXR_S_DISABLED) != (i32)0);
    c.identityCtl.nameField.setText((u8*)"okButton");
    c.identityCtl.onEdit(c.identityCtl.nameField);
    checkTrue("and a name is every layout's", streq(okIn(c, (i32)1).name, (u8*)"okButton"));

    Stdio.printf("-- saved with the document\n");
    Data* b = UXRscWriter.write(c.doc);
    UXRscDoc* back = UXRscReader.read(b.bytes(), b.length());
    RKVariants* vs = new RKVariants();
    vs.loadFrom(back);
    checkTrue("the phone still varies Text", vs.varies(back, back.treeAt((i32)1), back.treeAt((i32)1).root.childAt((i32)0), (u8*)"Text"));
    checkTrue("the desktop does not", !vs.varies(back, back.treeAt((i32)0), back.treeAt((i32)0).root.childAt((i32)0), (u8*)"Text"));

    Stdio.printf("-- shared again\n");
    c.viewLayout((i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT);
    c.selectObject(okIn(c, (i32)1));
    vary(c, (u8*)"Text");
    checkTrue("the phone takes the shared text back", streq(okIn(c, (i32)1).text, (u8*)"Finish"));
    checkTrue("the toggle reads Vary", streq(c.inspectorCtl.rowNamed((u8*)"Text").vary.title, (u8*)"Vary"));
    c.onUndo((UXMenuItem*)0);
    checkTrue("undo: it varies again", streq(okIn(c, (i32)1).text, (u8*)"Go") &&
              c.variants.varies(c.doc, c.doc.treeAt((i32)1), okIn(c, (i32)1), (u8*)"Text"));

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: layouts share what a control says, and vary it where asked\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
