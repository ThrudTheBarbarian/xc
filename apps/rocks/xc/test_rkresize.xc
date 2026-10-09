// test_rkresize.xc — autoresizing in a document: the Size inspector sets how a control follows its
// container, in the layout on the canvas only; the setting is saved, undone with everything else,
// and the loader gives the views it makes those masks, so a resized form lays them out.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXGeometry.xc"
#import "UXRsc.xc"
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
UXRscObject* childIn(RKMainController* c, i32 tree, i32 i)
    {
    return c.doc.treeAt(tree).root.childAt(i);
    }
// tick the Size inspector's row
// Toggle one bit on the Size tab's Autosizing widget (a click on its strut or spring); the widget
// writes it to the model through the inspector.
void toggleBit(RKMainController* c, i32 bit)
    {
    c.sizeCtl.autoSizing.toggle(bit);
    }
// the view the loader made for the object at `i` among the form's children
UXView* loadedChild(UXRscInstance* ni, UXRscObject* o)
    {
    for (u32 i = (u32)0; i < ni.objs.count(); i = i + (u32)1)
        {
        if ((UXRscObject* ?)ni.objs.get(i) == o)
            {
            return (UXView* ?)ni.views.get(i);
            }
        }
    return (UXView*)0;
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
    UXRscObject* panel = UXRscObject.make((i32)UXR_T_BOX, (i32)10, (i32)10, (i32)280, (i32)150);
    desk.root.addChild(panel);
    UXRscObject* ok = UXRscObject.make((i32)UXR_T_BUTTON, (i32)220, (i32)170, (i32)60, (i32)20);
    ok.text = (u8*)"OK";
    desk.root.addChild(ok);
    r.addTree(desk);
    r.addVariant(desk, (i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT);
    c.showResource(r, (i32)0);
    win.tree.finalise();

    Stdio.printf("-- the Size inspector\n");
    c.selectObject(childIn(c, (i32)0, (i32)0));
    checkTrue("it offers the Autosizing widget", c.sizeCtl.autoSizing != (RKAutoSizing*)0);
    checkTrue("the Attributes tab does not", c.inspectorCtl.autoSizing == (RKAutoSizing*)0);
    checkTrue("pinned top left to begin with", (c.sizeCtl.autoSizing.maskOf() & (i32)UX_FLEX_WIDTH) == (i32)0);
    toggleBit(c, (i32)UX_FLEX_WIDTH);
    toggleBit(c, (i32)UX_FLEX_HEIGHT);
    check("the panel stretches", c.doc.autoresizeOf(c.doc.treeAt((i32)0), childIn(c, (i32)0, (i32)0)),
          (i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));
    checkTrue("stored as letters", streq(c.doc.attrIn(c.doc.formIdOf(c.doc.treeAt((i32)0)), childIn(c, (i32)0, (i32)0).logicalId,
          (i32)c.doc.themeOf(c.doc.treeAt((i32)0)), (u8*)"autoresize"), (u8*)"WH"));
    check("the phone's panel does not", c.doc.autoresizeOf(c.doc.treeAt((i32)1), childIn(c, (i32)1, (i32)0)), (i32)0);
    c.selectObject(childIn(c, (i32)0, (i32)1));
    toggleBit(c, (i32)UX_ANCHOR_RIGHT);
    toggleBit(c, (i32)UX_ANCHOR_BOTTOM);
    check("OK keeps the bottom right corner", c.doc.autoresizeOf(c.doc.treeAt((i32)0), childIn(c, (i32)0, (i32)1)),
          (i32)(UX_ANCHOR_RIGHT | UX_ANCHOR_BOTTOM));
    c.selectObject(childIn(c, (i32)0, (i32)0));
    checkTrue("re-shown, the widget says so", (c.sizeCtl.autoSizing.maskOf() & (i32)UX_FLEX_HEIGHT) != (i32)0);

    Stdio.printf("-- undo\n");
    toggleBit(c, (i32)UX_FLEX_HEIGHT);
    check("unticked", c.doc.autoresizeOf(c.doc.treeAt((i32)0), childIn(c, (i32)0, (i32)0)), (i32)UX_FLEX_WIDTH);
    c.onUndo((UXMenuItem*)0);
    check("undo: it stretches both ways again", c.doc.autoresizeOf(c.doc.treeAt((i32)0), childIn(c, (i32)0, (i32)0)),
          (i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));

    Stdio.printf("-- saved, and loaded\n");
    Data* b = UXRscWriter.write(c.doc);
    UXRscDoc* back = UXRscReader.read(b.bytes(), b.length());
    check("the panel's mask survives a save", back.autoresizeOf(back.treeAt((i32)0), back.treeAt((i32)0).root.childAt((i32)0)),
          (i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));
    UXView* host = new UXView();
    content.addSubview(host, UXGeom.make((i16)0, (i16)0, (i16)300, (i16)200));
    UXRscInstance* ni = UXRsc.loadDoc(back, back.formIdOf(back.treeAt((i32)0)), (UXDesignable*)0, host);
    checkTrue("the form loads", ni != (UXRscInstance*)0);
    UXView* pv = loadedChild(ni, back.treeAt((i32)0).root.childAt((i32)0));
    UXView* ov = loadedChild(ni, back.treeAt((i32)0).root.childAt((i32)1));
    check("the panel's view has the mask", pv.autoresizeMask, (i32)(UX_FLEX_WIDTH | UX_FLEX_HEIGHT));
    check("OK's view has its mask", ov.autoresizeMask, (i32)(UX_ANCHOR_RIGHT | UX_ANCHOR_BOTTOM));
    UXView* host2 = new UXView();
    content.addSubview(host2, UXGeom.make((i16)400, (i16)0, (i16)300, (i16)200));
    UXRscInstance* ph = UXRsc.loadDocAs(back, back.formIdOf(back.treeAt((i32)0)), (i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT,
                                        (UXDesignable*)0, host2);
    check("the phone layout's panel is pinned", loadedChild(ph, back.treeAt((i32)1).root.childAt((i32)0)).autoresizeMask, (i32)0);
    ni.root.setFrame(UXGeom.make((i16)0, (i16)0, (i16)400, (i16)260));
    ni.root.resizeSubviews((i32)300, (i32)200, (i32)400, (i32)260);
    check("a wider form: the panel is wider", (i32)pv.frame().w, (i32)380);
    check("and taller", (i32)pv.frame().h, (i32)210);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: autoresizing is set per layout, saved, undone and loaded\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
