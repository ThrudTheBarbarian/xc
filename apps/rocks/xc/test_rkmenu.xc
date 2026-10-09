// test_rkmenu.xc — making menus.  A menu is an ordinary tree in the classic GEM shape; the library
// makes one, items go into it, and it must survive a save/load still a menu.
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
bool eqs(u8* a, u8* b)
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
UXRscTree* menuIn(UXRscDoc* d)
    {
    for (i32 i = (i32)0; i < d.treeCount(); i = i + (i32)1)
        {
        if (d.treeAt(i).isMenu())
            {
            return d.treeAt(i);
            }
        }
    return (UXRscTree*)0;
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
    win.open((u8*)"menu", UXGeom.make((i16)0, (i16)0, (i16)900, (i16)600), content);
    RKMainController* c = new RKMainController();
    checkTrue("the window wires", RKMainBuilder.buildInto(content, c, (i16)900, (i16)600));

    UXRscDoc* r = new UXRscDoc();
    UXRscTree* t0 = new UXRscTree();
    t0.root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)300, (i32)200);
    t0.root.addChild(UXRscObject.make((i32)UXR_T_BUTTON, (i32)20, (i32)20, (i32)60, (i32)20));
    r.addTree(t0);
    c.showResource(r, (i32)0);
    win.tree.finalise();

    i32 before = r.treeCount();
    c.libraryPick(c.library.named((u8*)"Menu"));
    check("a menu tree is added", r.treeCount(), before + (i32)1);
    UXRscTree* mt = menuIn(r);
    checkTrue("it is a menu", mt != (UXRscTree*)0);
    check("with one title", mt != (UXRscTree*)0 ? RKMenu.titleCount(mt) : (i32)0, (i32)1);
    UXRscObject* dd = mt != (UXRscTree*)0 ? RKMenu.dropdownAt(mt, (i32)0) : (UXRscObject*)0;
    check("and three items", dd != (UXRscObject*)0 ? dd.childCount() : (i32)0, (i32)3);
    checkTrue("the first reads New", dd != (UXRscObject*)0 && eqs(dd.childAt((i32)0).text, (u8*)"New"));
    checkTrue("the second is a separator", dd != (UXRscObject*)0 && eqs(dd.childAt((i32)1).text, (u8*)"-"));
    check("the menu is shown on the canvas", c.shownTree, r.indexOfTree(mt));

    // "Menu Item" appends to the shown menu's title.
    c.libraryPick(c.library.named((u8*)"Menu Item"));
    dd = RKMenu.dropdownAt(mt, (i32)0);
    check("a menu item is appended", dd.childCount(), (i32)4);

    // It must survive a save/load and still BE a menu (the reader detects it by shape).
    Data* b = UXRscWriter.write(r);
    UXRscDoc* back = UXRscReader.reader(b.bytes(), (i32)b.length()).result;
    checkTrue("the document round-trips", back != (UXRscDoc*)0);
    UXRscTree* m2 = back != (UXRscDoc*)0 ? menuIn(back) : (UXRscTree*)0;
    checkTrue("the menu comes back a menu", m2 != (UXRscTree*)0);
    check("with its one title", m2 != (UXRscTree*)0 ? RKMenu.titleCount(m2) : (i32)0, (i32)1);
    UXRscObject* d2 = m2 != (UXRscTree*)0 ? RKMenu.dropdownAt(m2, (i32)0) : (UXRscObject*)0;
    check("and its four items", d2 != (UXRscObject*)0 ? d2.childCount() : (i32)0, (i32)4);
    checkTrue("with the separator intact", d2 != (UXRscObject*)0 && eqs(d2.childAt((i32)1).text, (u8*)"-"));

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: menus are made, filled, and survive a save/load\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
