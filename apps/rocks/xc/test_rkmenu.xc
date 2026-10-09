// test_rkmenu.xc — making menus.  A menu is an ordinary tree in the classic GEM shape; the library
// makes one, items go into it, one menu is the application's MAIN menu (swappable), and all of it
// survives a save/load.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXGeometry.xc"
#import "UXRscModel.xc"
#import "UXRsc.xc"
#import "UXRscRead.xc"
#import "UXRscWrite.xc"
#import "UXMenu.xc"
#import "RKMainController.xc"
#import "RKMainBuilder.xc"
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
UXRscTree* nthMenu(UXRscDoc* d, i32 n)
    {
    i32 seen = (i32)0;
    for (i32 i = (i32)0; i < d.treeCount(); i = i + (i32)1)
        {
        if (d.treeAt(i).isMenu())
            {
            if (seen == n)
                {
                return d.treeAt(i);
                }
            seen = seen + (i32)1;
            }
        }
    return (UXRscTree*)0;
    }
i32 menuCount(UXRscDoc* d)
    {
    i32 c = (i32)0;
    for (i32 i = (i32)0; i < d.treeCount(); i = i + (i32)1)
        {
        if (d.treeAt(i).isMenu())
            {
            c = c + (i32)1;
            }
        }
    return c;
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

    // ---- make a menu, fill it -------------------------------------------------
    c.libraryPick(c.library.named((u8*)"Menu"));
    check("a menu tree is added", menuCount(r), (i32)1);
    UXRscTree* mt = nthMenu(r, (i32)0);
    checkTrue("it is a menu", mt != (UXRscTree*)0);
    check("with one title", mt != (UXRscTree*)0 ? RKMenu.titleCount(mt) : (i32)0, (i32)1);
    UXRscObject* dd = mt != (UXRscTree*)0 ? RKMenu.dropdownAt(mt, (i32)0) : (UXRscObject*)0;
    check("and three items", dd != (UXRscObject*)0 ? dd.childCount() : (i32)0, (i32)3);
    checkTrue("the first reads New", dd != (UXRscObject*)0 && eqs(dd.childAt((i32)0).text, (u8*)"New"));
    checkTrue("the second is a separator", dd != (UXRscObject*)0 && eqs(dd.childAt((i32)1).text, (u8*)"-"));
    check("the menu is shown on the canvas", c.shownTree, r.indexOfTree(mt));
    c.libraryPick(c.library.named((u8*)"Menu Item"));
    dd = RKMenu.dropdownAt(mt, (i32)0);
    check("a menu item is appended", dd.childCount(), (i32)4);

    // ---- more than one menu; the main-menu link ---------------------------------
    c.libraryPick(c.library.named((u8*)"Menu"));
    check("a second menu", menuCount(r), (i32)2);
    UXRscTree* mb2 = nthMenu(r, (i32)1);
    dd = RKMenu.dropdownAt(mb2, (i32)0);
    if (dd != (UXRscObject*)0 && dd.childCount() > (i32)0)
        {
        dd.childAt((i32)0).name = (u8*)"onNew"; // the action this item carries, by name
        }
    c.onSetMainMenu(); // the shown menu (the second) becomes the main one
    checkTrue("the second menu is the main one", r.mainMenuTree() == mb2);
    check("the document records its index", r.mainMenu, r.indexOfTree(mb2));
    UXMenuBar* bar = UXRsc.loadMainMenu(r);
    checkTrue("the main menu builds a bar", bar != (UXMenuBar*)0);
    check("with one menu on it", bar != (UXMenuBar*)0 ? (i32)bar.menus.count() : (i32)0, (i32)1);
    checkTrue("and the item carries its action name",
              bar != (UXMenuBar*)0 && bar.itemNamed((u8*)"onNew") != (UXMenuItem*)0);
    // the outline marks which menu is the main one
    u8* lbl = RKOutline.treeLabel(mb2, (i32)1, true);
    checkTrue("the outline marks the main menu", eqs(lbl, (u8*)"Menu (main)"));

    // swapping: make the first menu the main one
    c.showResource(r, r.indexOfTree(mt));
    c.onSetMainMenu();
    checkTrue("after a swap the first is main", r.mainMenuTree() == mt);

    // ---- it survives a save/load -----------------------------------------------
    Data* b = UXRscWriter.write(r);
    UXRscDoc* back = UXRscReader.reader(b.bytes(), (i32)b.length()).result;
    checkTrue("the document round-trips", back != (UXRscDoc*)0);
    check("two menus come back", back != (UXRscDoc*)0 ? menuCount(back) : (i32)0, (i32)2);
    UXRscTree* m2 = back != (UXRscDoc*)0 ? nthMenu(back, (i32)1) : (UXRscTree*)0;
    checkTrue("the second is still the menu with the action item",
              m2 != (UXRscTree*)0 && RKMenu.dropdownAt(m2, (i32)0) != (UXRscObject*)0 &&
              eqs(RKMenu.dropdownAt(m2, (i32)0).childAt((i32)0).name, (u8*)"onNew"));
    checkTrue("and the main-menu link came back", back != (UXRscDoc*)0 && back.mainMenuTree() != (UXRscTree*)0);
    checkTrue("pointing at the first menu (the swap)", back != (UXRscDoc*)0 && back.mainMenuTree().isMenu() &&
              !eqs(back.mainMenuTree().name, (u8*)"second"));

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: menus are made, filled, linked as the main menu, and survive a save/load\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
