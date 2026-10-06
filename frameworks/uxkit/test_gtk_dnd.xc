// test_gtk_dnd.xc — drags and drops, context menus and a window's line, on GTK: a table's rows
// drag out, an outline's rows drag out and take drops, drops and hovers reach the application,
// the outline's item under a point is found, UXMenu.popUp fires the item picked, and
// UXWindow.showLine draws above the native controls, and a title changed later reaches the screen.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXMenu.xc"
#import "UXTableView.xc"
#import "UXOutlineView.xc"
#import "UXGeometry.xc"

extern void ux_gtk_wait_allocated(i32 handle);
extern i32 ux_gtk_test_row_drag(i32 handle, i32 node, i32 row, u8* buf, i32 n);
extern i32 ux_gtk_test_outline_drag(i32 handle, i32 node, pointer item, u8* buf, i32 n);
extern i32 ux_gtk_test_drop_item(i32 handle, u8* text, i32 x, i32 y);
extern i32 ux_gtk_test_hover_item(i32 handle, u8* text, i32 x, i32 y);
extern i32 ux_gtk_test_line(i32 handle, i32* x1, i32* y1);
extern void ux_gtk_test_menu_pick(i32 i);
extern void ux_gtk_pump(void);
extern void ux_gtk_frames(i32 n);
extern i32 ux_gtk_test_control_text(i32 handle, i32 node, u8* buf, i32 n);
extern u8* ux_gtk_test_menu_titles(void);

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

// a table of fruit, and an outline of two rows: "Owner" drags as "end:owner", "Group" does not drag
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
    i32 numberOfRows(UXTableView* t)
        {
        return (i32)3;
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        if (row == (i32)0)
            {
            return (u8*)"Apple";
            }
        return row == (i32)1 ? (u8*)"Pear" : (u8*)"Plum";
        }
    i32 numberOfChildren(UXOutlineView* o, Object* item)
        {
        return item == (Object*)0 ? (i32)2 : (i32)0;
        }
    Object* childOfItem(UXOutlineView* o, Object* item, i32 i)
        {
        return i == (i32)0 ? (Object*)owner : (Object*)group;
        }
    bool isExpandable(UXOutlineView* o, Object* item)
        {
        return false;
        }
    u8* valueForItem(UXOutlineView* o, Object* item, i32 col)
        {
        return ((Node* ?)item).name;
        }
    u8* dragTextForItem(UXOutlineView* o, Object* item)
        {
        return ((Node* ?)item).drag;
        }
    }

u8 gDropped[64];
i32 gDropX;
i32 gHoverX;
i32 gPicked;
class Ctl : Object
    {
    void onDrop(u8* item, i32 window, i32 x, i32 y)
        {
        i32 i = (i32)0;
        while (item[i] != (u8)0 && i < (i32)63)
            {
            gDropped[i] = item[i];
            i = i + (i32)1;
            }
        gDropped[i] = (u8)0;
        gDropX = x;
        }
    void onHover(u8* item, i32 window, i32 x, i32 y)
        {
        gHoverX = x;
        }
    void onFirst(UXMenuItem* s) { gPicked = (i32)1; }
    void onSecond(UXMenuItem* s) { gPicked = (i32)2; }
    }

void main(void)
    {
    UXGtkDriver* d = new UXGtkDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display for gtk_init\n");
        return;
        }
    UXApplication* app = new UXApplication();
    gApp = app; // what run() sets; this test delivers without running the loop
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
    win.tree.finalise();
    win.displayAll();
    outline.reloadData();
    ux_gtk_wait_allocated(win.handle);

    u8 buf[64];
    ck(ux_gtk_test_row_drag(win.handle, (i32)table.index, (i32)1, &buf[(i32)0], (i32)64) == (i32)0,
       "a table whose rows do not drag gives nothing", (i32)0);
    table.setDragsRows(true);
    ck(ux_gtk_test_row_drag(win.handle, (i32)table.index, (i32)1, &buf[(i32)0], (i32)64) == (i32)1 && streq(&buf[(i32)0], (u8*)"Pear"),
       "with setDragsRows, row 1 drags out as its first column", (i32)buf[(i32)0]);
    ck(ux_gtk_test_outline_drag(win.handle, (i32)outline.index, (pointer)src.owner, &buf[(i32)0], (i32)64) == (i32)1 &&
       streq(&buf[(i32)0], (u8*)"end:owner"), "an outline row drags out as dragTextForItem says", (i32)buf[(i32)0]);
    ck(ux_gtk_test_outline_drag(win.handle, (i32)outline.index, (pointer)src.group, &buf[(i32)0], (i32)64) == (i32)0,
       "and a row it gives no text for does not drag", (i32)0);

    ck(ux_gtk_test_hover_item(win.handle, (u8*)"Pear", (i32)300, (i32)200) == (i32)1 && gHoverX == (i32)300,
       "a row dragged over the window reaches the hover handler", gHoverX);
    ck(ux_gtk_test_drop_item(win.handle, (u8*)"Pear", (i32)250, (i32)220) == (i32)1 && streq(&gDropped[(i32)0], (u8*)"Pear") &&
       gDropX == (i32)250, "and dropped, the drop handler, with its point", gDropX);

    // the outline's first row is near its top: find it by its point
    UXRect of = outline.absoluteFrame();
    ux_gtk_frames((i32)10); // the rows are laid out over the next frames
    Object* hit = (Object*)0;
    for (i32 y = (i32)of.y + (i32)2; y < (i32)of.y + (i32)of.h && hit == (Object*)0; y = y + (i32)2)
        {
        hit = outline.itemAtWindowPoint((i32)of.x + (i32)40, y);
        }
    ck(hit == (Object*)src.owner, "the item under a point of the outline is its first row's", hit != (Object*)0 ? (i32)1 : (i32)0);
    ck(outline.itemAtWindowPoint((i32)of.x - (i32)20, (i32)of.y + (i32)10) == (Object*)0, "and outside it, none", (i32)0);

    i32 lx = (i32)0;
    i32 ly = (i32)0;
    ck(win.showLine((i32)20, (i32)20, (i32)300, (i32)100, UXGeom.make((i16)280, (i16)90, (i16)40, (i16)20)),
       "the window draws a line above its controls", (i32)0);
    ck(ux_gtk_test_line(win.handle, &lx, &ly) == (i32)1 && lx == (i32)300 && ly == (i32)100, "to its far end", lx);
    win.hideLine();
    ck(ux_gtk_test_line(win.handle, &lx, &ly) == (i32)0, "and takes it down", (i32)0);

    UXMenu* m = new UXMenu();
    m.addItem((u8*)"First", &c.onFirst);
    m.addSeparator();
    UXMenuItem* second = m.addItem((u8*)"Second", &c.onSecond);
    ux_gtk_test_menu_pick((i32)2);
    ck(m.popUp(win.handle, (i32)100, (i32)100) && gPicked == (i32)2, "a context menu fires the item picked", gPicked);
    ck(streq(ux_gtk_test_menu_titles(), (u8*)"First|-|Second"), "showing its items and separator", (i32)0);
    second.enabled = false;
    gPicked = (i32)0;
    ux_gtk_test_menu_pick((i32)2);
    ck(!m.popUp(win.handle, (i32)100, (i32)100) && gPicked == (i32)0, "a disabled item does not fire", gPicked);

    // a title changed after the control is on screen reaches the GtkButton
    UXButton* b = new UXButton();
    b.setTitle((u8*)"Button");
    content.addSubview(b, UXGeom.make((i16)10, (i16)180, (i16)100, (i16)24));
    win.displayAll();
    b.setTitle((u8*)"Stop");
    win.displayAll();
    ux_gtk_test_control_text(win.handle, (i32)b.index, &buf[(i32)0], (i32)64);
    ck(streq(&buf[(i32)0], (u8*)"Stop"), "a button's title set after it is made reaches the GtkButton", (i32)buf[(i32)0]);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: GTK drags, drops, context menus and the window's line\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", gFails);
        }
    }
