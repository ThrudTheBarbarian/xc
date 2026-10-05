// test_gtk_menu.xc — the menu bar on GTK: a real GtkPopoverMenuBar over a GMenu, one action per item.
// Checked through the platform's own objects: the window shows a bar with the model's titles; an
// item picked (activated through its action, the path a click takes) fires the item's action in the
// toolkit; a pre-ticked item is ticked; setChecked ticks an item that was never ticked and setEnabled
// greys one so a pick no longer fires; a window opened afterwards has the bar too; and the content
// keeps the size it was opened at.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXMenu.xc"
#import "UXGeometry.xc"

extern void ux_gtk_menu_test_activate(i32 t, i32 j);
extern i32 ux_gtk_menu_test_state(i32 t, i32 j);
extern i32 ux_gtk_menu_test_titles(i32 h);
extern void ux_gtk_wait_allocated(i32 handle);
extern i32 ux_gtk_menu_test_accel(i32 t, i32 j, u8* buf, i32 cap);
extern i32 ux_gtk_menu_test_shortcuts(i32 h, i32 fire);

i32 gFails = 0;
void ck(bool ok, u8* what, i32 v)
    {
    Stdio.printf("  %s %s (%d)\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what, v);
    if (!ok)
        {
        gFails = gFails + 1;
        }
    }
i32 gNew;
i32 gQuit;
i32 gGrid;
i32 gUndo;
i32 gRedo;
bool streq(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
class Ctl : Object
    {
    void onNew(UXMenuItem* s) { gNew = gNew + (i32)1; }
    void onQuit(UXMenuItem* s) { gQuit = gQuit + (i32)1; }
    void onGrid(UXMenuItem* s) { gGrid = gGrid + (i32)1; }
    void onUndo(UXMenuItem* s) { gUndo = gUndo + (i32)1; }
    void onRedo(UXMenuItem* s) { gRedo = gRedo + (i32)1; }
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
    gApp = app; // what run() sets; this test dispatches without running the loop
    UXWindow* win = new UXWindow();
    win.open((u8*)"Menus", UXGeom.make((i16)80, (i16)80, (i16)240, (i16)140), new UXView());
    app.addWindow(win);
    Ctl* c = new Ctl();
    UXMenuBar* bar = new UXMenuBar();
    UXMenu* file = bar.addMenu((u8*)"File");
    file.addItem((u8*)"New", &c.onNew);
    file.addSeparator();
    file.addItem((u8*)"Quit", &c.onQuit);
    UXMenu* view = bar.addMenu((u8*)"View");
    UXMenuItem* grid = view.addItem((u8*)"Grid", &c.onGrid);
    grid.checked = true;
    view.addItem((u8*)"Rulers", &c.onGrid);
    UXMenu* edit = bar.addMenu((u8*)"Edit");
    edit.addItem((u8*)"Undo", &c.onUndo).setShortcut((u8)'Z', false);
    edit.addItem((u8*)"Redo", &c.onRedo).setShortcut((u8)'Z', true);
    app.setMenuBar(bar);
    win.displayAll();
    ux_gtk_wait_allocated(win.handle);

    ck(ux_gtk_menu_test_titles(win.handle) == (i32)3, "the window shows a menu bar with the three titles", ux_gtk_menu_test_titles(win.handle));
    u8 acc[32];
    ck(ux_gtk_menu_test_accel((i32)2, (i32)0, &acc[(i32)0], (i32)32) == (i32)1 && streq(&acc[(i32)0], (u8*)"<Control>z"),
       "Edit > Undo shows <Control>z", (i32)acc[(i32)0]);
    ck(ux_gtk_menu_test_accel((i32)2, (i32)1, &acc[(i32)0], (i32)32) == (i32)1 && streq(&acc[(i32)0], (u8*)"<Control><Shift>z"),
       "Edit > Redo shows <Control><Shift>z", (i32)acc[(i32)0]);
    ck(ux_gtk_menu_test_accel((i32)0, (i32)0, &acc[(i32)0], (i32)32) == (i32)0, "File > New has none", (i32)0);
    ck(ux_gtk_menu_test_shortcuts(win.handle, (i32)-1) == (i32)2, "the window holds both shortcuts", ux_gtk_menu_test_shortcuts(win.handle, (i32)-1));
    ux_gtk_menu_test_shortcuts(win.handle, (i32)1);
    ck(gRedo == (i32)1 && gUndo == (i32)0, "the Redo shortcut fires Redo", gRedo * (i32)10 + gUndo);
    ux_gtk_menu_test_activate((i32)0, (i32)0);
    ck(gNew == (i32)1, "picking File > New fires its action", gNew);
    ux_gtk_menu_test_activate((i32)0, (i32)2);
    ck(gQuit == (i32)1 && gNew == (i32)1, "File > Quit (after the separator) fires its own", gQuit);
    ck(ux_gtk_menu_test_state((i32)1, (i32)0) == (i32)3, "View > Grid starts ticked", ux_gtk_menu_test_state((i32)1, (i32)0));
    ck(ux_gtk_menu_test_state((i32)1, (i32)1) == (i32)1, "View > Rulers starts unticked", ux_gtk_menu_test_state((i32)1, (i32)1));
    bar.setChecked((u16)1, (u16)1, true);
    ck(ux_gtk_menu_test_state((i32)1, (i32)1) == (i32)3, "setChecked ticks an item that was never ticked", ux_gtk_menu_test_state((i32)1, (i32)1));
    bar.setChecked((u16)1, (u16)0, false);
    ck(ux_gtk_menu_test_state((i32)1, (i32)0) == (i32)1, "...and clears a ticked one", ux_gtk_menu_test_state((i32)1, (i32)0));
    bar.setEnabled((u16)0, (u16)0, false);
    ck(ux_gtk_menu_test_state((i32)0, (i32)0) == (i32)0, "setEnabled greys File > New", ux_gtk_menu_test_state((i32)0, (i32)0));
    ux_gtk_menu_test_activate((i32)0, (i32)0);
    ck(gNew == (i32)1, "...and a pick of it no longer fires", gNew);
    i32 cw = (i32)0;
    i32 chh = (i32)0;
    gDriver.windowContentGeometry(win.handle, &cw, &chh);
    ck(cw == (i32)240 && chh == (i32)140, "the content keeps its size under the bar", cw * (i32)1000 + chh);
    UXWindow* late = new UXWindow();
    late.open((u8*)"Later", UXGeom.make((i16)360, (i16)80, (i16)200, (i16)100), new UXView());
    app.addWindow(late);
    late.displayAll();
    ck(ux_gtk_menu_test_titles(late.handle) == (i32)3, "a window opened afterwards has the bar too", ux_gtk_menu_test_titles(late.handle));
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: GTK menus -- a native menu bar, picks, ticks, greying, every window\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
