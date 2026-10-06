// test_win32_dnd.xc — drags, drops, context menus, the drag line, minimum size and late titles on
// Win32: a list's rows drag out (the left button), a tree's rows drag out on the right button and
// report where they began, the tree's item under a point is found, UXMenu.popUp fires the item
// picked, UXWindow.showLine draws above the controls, WM_GETMINMAXINFO keeps to setMinimumSize, and
// a button renamed after it is made says so.  Drags are driven with posted mouse messages, so the
// real pointer is never moved.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXMenu.xc"
#import "UXTableView.xc"
#import "UXOutlineView.xc"
#import "UXGeometry.xc"

i32 gFails = 0;
void ck(bool ok, u8* what, i32 v)
    {
    Stdio.printf("  %s %s (%d)\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what, v);
    if (!ok)
        {
        gFails = gFails + 1;
        }
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
class Node : Object
    {
    u8* name;
    u8* drag;
    }
class Src : Object<UXTableDataSource, UXOutlineDataSource>
    {
    Node* owner;
    Node* group;
    void init(void)
        {
        owner = new Node();
        owner.name = (u8*)"Owner";
        owner.drag = (u8*)"end:owner";
        group = new Node();
        group.name = (u8*)"Group";
        group.drag = (u8*)0;
        }
    i32 numberOfRows(UXTableView* t) { return (i32)3; }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        if (row == (i32)0) { return (u8*)"Apple"; }
        return row == (i32)1 ? (u8*)"Pear" : (u8*)"Plum";
        }
    i32 numberOfChildren(UXOutlineView* o, Object* item) { return item == (Object*)0 ? (i32)2 : (i32)0; }
    Object* childOfItem(UXOutlineView* o, Object* item, i32 i) { return i == (i32)0 ? (Object*)owner : (Object*)group; }
    bool isExpandable(UXOutlineView* o, Object* item) { return false; }
    u8* valueForItem(UXOutlineView* o, Object* item, i32 col) { return ((Node* ?)item).name; }
    u8* dragTextForItem(UXOutlineView* o, Object* item) { return ((Node* ?)item).drag; }
    }
u8 gDropped[64];
i32 gDropX;
i32 gHovers;
i32 gFirstHoverX;
i32 gLastHoverX;
i32 gPicked;
class Ctl : Object
    {
    void onDrop(u8* item, i32 window, i32 x, i32 y)
        {
        i32 i = (i32)0;
        while (item[i] != (u8)0 && i < (i32)63) { gDropped[i] = item[i]; i = i + (i32)1; }
        gDropped[i] = (u8)0;
        gDropX = x;
        }
    void onHover(u8* item, i32 window, i32 x, i32 y)
        {
        if (gHovers == (i32)0) { gFirstHoverX = x; }
        gHovers = gHovers + (i32)1;
        gLastHoverX = x;
        }
    void onFirst(UXMenuItem* s) { gPicked = (i32)1; }
    void onSecond(UXMenuItem* s) { gPicked = (i32)2; }
    }
pointer ctrlOf(i32 handle, UXView* v)
    {
    W32Tree* t = (W32Tree*)gW32TreeOf[handle];
    return t.nodes[(i32)v.index].ctrl;
    }
pointer lparam(i32 x, i32 y)
    {
    return (pointer)(((u32)y << (u32)16) | ((u32)x & (u32)$FFFF));
    }

void main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    d.boot(&sw, &sh);
    UXApplication* app = new UXApplication();
    gApp = app;
    Ctl* c = new Ctl();
    app.setItemDropHandler(&c.onDrop);
    app.setItemHoverHandler(&c.onHover);
    Src* src = new Src();
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"Drags", UXGeom.make((i16)80, (i16)80, (i16)420, (i16)260), content);
    app.addWindow(win);
    UXTableView* table = new UXTableView();
    table.addColumn((u8*)"Fruit", (i16)120);
    table.setDataSource((UXTableDataSource*)src);
    content.addSubview(table, UXGeom.make((i16)10, (i16)10, (i16)180, (i16)120));
    UXOutlineView* outline = new UXOutlineView();
    outline.addColumn((u8*)"", (i16)160);
    outline.setOutlineSource((UXOutlineDataSource*)src);
    content.addSubview(outline, UXGeom.make((i16)210, (i16)10, (i16)180, (i16)120));
    UXButton* b = new UXButton();
    b.setTitle((u8*)"Button");
    content.addSubview(b, UXGeom.make((i16)10, (i16)180, (i16)100, (i16)24));
    win.tree.finalise();
    win.displayAll();
    outline.reloadData();
    win.displayAll();
    pointer main = gW32Hwnds[win.handle];

    // a list's row, dragged out with the left button: hovers, then the drop with its point
    table.setDragsRows(true);
    PostMessageA(main, (u32)WM_MOUSEMOVE, (pointer)0, lparam((i32)300, (i32)200));
    PostMessageA(main, (u32)WM_LBUTTONUP, (pointer)0, lparam((i32)250, (i32)220));
    NMLISTVIEW nl;
    nl.hwndFrom = ctrlOf(win.handle, (UXView*)table);
    nl.idFrom = (pointer)0;
    nl.code = (u32)LVN_BEGINDRAG;
    nl.iItem = (i32)1;
    nl.iSubItem = (i32)0;
    nl.ptx = (i32)5;
    nl.pty = (i32)5;
    SendMessageA(main, (u32)WM_NOTIFY, (pointer)0, (pointer)&nl);
    ck(gHovers >= (i32)2 && gFirstHoverX == (i32)300, "a list row's drag reports where it is", gFirstHoverX);
    ck(streq(&gDropped[(i32)0], (u8*)"Pear") && gDropX == (i32)250, "and drops its first column where it is let go", gDropX);
    ck(gLastHoverX == (i32)-1, "and the hover ends", gLastHoverX);

    // a tree's row, dragged with the right button: it starts by reporting where it began
    gHovers = (i32)0;
    gDropped[(i32)0] = (u8)0;
    PostMessageA(main, (u32)WM_RBUTTONUP, (pointer)0, lparam((i32)120, (i32)60));
    NMTREEVIEW nt;
    nt.hwndFrom = ctrlOf(win.handle, (UXView*)outline);
    nt.idFrom = (pointer)0;
    nt.code = (u32)TVN_BEGINRDRAGA;
    nt.nLParam = (pointer)src.owner;
    nt.ptx = (i32)20;
    nt.pty = (i32)8;
    SendMessageA(main, (u32)WM_NOTIFY, (pointer)0, (pointer)&nt);
    // 210 + 20, and the tree's border before its client area
    ck(gFirstHoverX >= (i32)230 && gFirstHoverX <= (i32)232, "a tree row's drag begins at the row, in the window's terms", gFirstHoverX);
    ck(streq(&gDropped[(i32)0], (u8*)"end:owner"), "and drops what dragTextForItem says", (i32)gDropped[(i32)0]);
    gDropped[(i32)0] = (u8)0;
    nt.nLParam = (pointer)src.group;
    PostMessageA(main, (u32)WM_RBUTTONUP, (pointer)0, lparam((i32)120, (i32)60));
    SendMessageA(main, (u32)WM_NOTIFY, (pointer)0, (pointer)&nt);
    ck(gDropped[(i32)0] == (u8)0, "a row it gives no text for does not drag", (i32)0);
    MSG drain;
    while (PeekMessageA((pointer)&drain, (pointer)0, (u32)0, (u32)0, (u32)1) != (i32)0) { }

    // the tree's item under a point
    Object* hit = (Object*)0;
    for (i32 y = (i32)12; y < (i32)120 && hit == (Object*)0; y = y + (i32)2)
        {
        hit = outline.itemAtWindowPoint((i32)240, y);
        }
    ck(hit == (Object*)src.owner, "the tree's item under a point is its first row's", hit != (Object*)0 ? (i32)1 : (i32)0);
    ck(outline.itemAtWindowPoint((i32)195, (i32)20) == (Object*)0, "and outside it, none", (i32)0);

    // the line, above the controls
    i32 lx = (i32)0;
    i32 ly = (i32)0;
    ck(win.showLine((i32)20, (i32)20, (i32)300, (i32)100, UXGeom.make((i16)280, (i16)90, (i16)40, (i16)20)), "the window draws a line above its controls", (i32)0);
    ck(w32TestLine(win.handle, &lx, &ly) == (i32)1 && lx == (i32)300 && ly == (i32)100, "to its far end", lx);
    win.hideLine();
    ck(w32TestLine(win.handle, &lx, &ly) == (i32)0, "and takes it down", (i32)0);

    // a context menu
    UXMenu* m = new UXMenu();
    m.addItem((u8*)"First", &c.onFirst);
    m.addSeparator();
    UXMenuItem* second = m.addItem((u8*)"Second", &c.onSecond);
    gW32MenuTestPick = (i32)2;
    ck(m.popUp(win.handle, (i32)100, (i32)100) && gPicked == (i32)2, "a context menu fires the item picked", gPicked);
    ck(streq(&gW32MenuTestTitles[(i32)0], (u8*)"First|-|Second"), "showing its items and separator", (i32)0);
    second.enabled = false;
    gPicked = (i32)0;
    gW32MenuTestPick = (i32)2;
    ck(!m.popUp(win.handle, (i32)100, (i32)100) && gPicked == (i32)0, "a disabled item does not fire", gPicked);

    // the minimum size
    win.setMinimumSize((i32)400, (i32)240);
    MINMAXINFO mm;
    mm.minTrackX = (i32)0;
    mm.minTrackY = (i32)0;
    SendMessageA(main, (u32)WM_GETMINMAXINFO, (pointer)0, (pointer)&mm);
    ck(mm.minTrackX > (i32)400 && mm.minTrackY > (i32)240, "the window cannot be made smaller than its minimum", mm.minTrackX);

    // a title set after the button is made
    b.setTitle((u8*)"Stop");
    win.displayAll();
    u8 buf[64];
    GetWindowTextA(ctrlOf(win.handle, (UXView*)b), (pointer)&buf[(i32)0], (i32)64);
    ck(streq(&buf[(i32)0], (u8*)"Stop"), "a button's title set after it is made reaches the BUTTON", (i32)buf[(i32)0]);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: Win32 drags, drops, context menus, the line, the minimum size and late titles\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", gFails);
        }
    }
