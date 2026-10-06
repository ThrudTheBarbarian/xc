// test_drawn_rowdrag.xc — a row dragged out of a table or an outline as the toolkit draws them (the
// backends with no native table: the web, GEM).  The press goes to the drawn row; the drag is
// followed through the driver's modal trackDragStep, which this test scripts, so no pointer moves.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXTableView.xc"
#import "UXOutlineView.xc"
#import "UXGeometry.xc"

// AppKit, but with the pointer's path scripted: each step a point, then the release.
class ScriptedDriver : UXAppKitDriver
    {
    i32 xs[8];
    i32 ys[8];
    i32 n;
    i32 at;
    bool dragTrackingIsModal(void)
        {
        return true;
        }
    i32 trackDragStep(i32* x, i32* y)
        {
        if (at >= n)
            {
            return (i32)0;
            }
        x[0] = xs[at];
        y[0] = ys[at];
        at = at + (i32)1;
        return (i32)1;
        }
    void script2(i32 x0, i32 y0, i32 x1, i32 y1)
        {
        xs[0] = x0; ys[0] = y0; xs[1] = x1; ys[1] = y1;
        n = (i32)2;
        at = (i32)0;
        }
    }

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
    void init(void)
        {
        owner = new Node();
        owner.name = (u8*)"Owner";
        owner.drag = (u8*)"end:owner";
        }
    i32 numberOfRows(UXTableView* t) { return (i32)3; }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        if (row == (i32)0) { return (u8*)"Apple"; }
        return row == (i32)1 ? (u8*)"Pear" : (u8*)"Plum";
        }
    i32 numberOfChildren(UXOutlineView* o, Object* item) { return item == (Object*)0 ? (i32)1 : (i32)0; }
    Object* childOfItem(UXOutlineView* o, Object* item, i32 i) { return (Object*)owner; }
    bool isExpandable(UXOutlineView* o, Object* item) { return false; }
    u8* valueForItem(UXOutlineView* o, Object* item, i32 col) { return ((Node* ?)item).name; }
    u8* dragTextForItem(UXOutlineView* o, Object* item) { return ((Node* ?)item).drag; }
    }
u8 gDropped[64];
i32 gDropX;
i32 gHovers;
i32 gFirstHoverX;
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
        }
    }

void main(void)
    {
    ux_ak_set_capture((i32)1);
    ScriptedDriver* d = new ScriptedDriver();
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
    win.open((u8*)"Drawn", UXGeom.make((i16)0, (i16)0, (i16)420, (i16)200), content);
    app.addWindow(win);
    UXTableView* table = new UXTableView();
    table.addColumn((u8*)"Fruit", (i16)120);
    table.setDataSource((UXTableDataSource*)src);
    content.addSubview(table, UXGeom.make((i16)10, (i16)10, (i16)180, (i16)120));
    UXOutlineView* outline = new UXOutlineView();
    outline.addColumn((u8*)"", (i16)160);
    outline.setOutlineSource((UXOutlineDataSource*)src);
    content.addSubview(outline, UXGeom.make((i16)210, (i16)10, (i16)180, (i16)120));
    win.tree.finalise();
    table.reloadData();
    outline.reloadData();
    win.displayAll();

    UXEvent* e = new UXEvent();
    e.x = (i16)40;
    e.y = (i16)40;
    UXTableRow* pear = (UXTableRow* ?)table.rows.get((u16)1);
    d.script2((i32)60, (i32)60, (i32)300, (i32)150);
    pear.mouseDown(e);
    ck(gDropped[(i32)0] == (u8)0, "a table that does not drag its rows sweeps a selection instead", (i32)0);
    table.setDragsRows(true);
    d.script2((i32)60, (i32)60, (i32)300, (i32)150);
    pear.mouseDown(e);
    ck(streq(&gDropped[(i32)0], (u8*)"Pear") && gDropX == (i32)300, "a drawn row drags out its first column, to where it is let go", gDropX);
    ck(gFirstHoverX == (i32)60, "hovering on the way", gFirstHoverX);
    gDropped[(i32)0] = (u8)0;
    d.script2((i32)41, (i32)41, (i32)42, (i32)41);
    pear.mouseDown(e);
    ck(gDropped[(i32)0] == (u8)0, "a press that does not move is a click, not a drag", (i32)0);

    gHovers = (i32)0;
    UXTableRow* ownerRow = (UXTableRow* ?)outline.rows.get((u16)0);
    e.x = (i16)230;
    e.y = (i16)30;
    d.script2((i32)250, (i32)60, (i32)100, (i32)150);
    ownerRow.rightMouseDown(e);
    ck(streq(&gDropped[(i32)0], (u8*)"end:owner"), "an outline's drawn row drags on the secondary button", (i32)gDropped[(i32)0]);
    ck(gFirstHoverX == (i32)230, "and reports where it began first", gFirstHoverX);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: rows drag out of tables and outlines the toolkit draws\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", gFails);
        }
    }
