// test_table_native.xc — UXTableView as the platform's real table on the mobile backends: a
// UITableView on iOS (the ios-table gate), a ListView on Android (android-table, built with
// -D TABLE_ANDROID: Android is plain arm64 to the compiler, so there is no target symbol to test).
// Rows and cells come from the table's own datasource, a row the USER taps lands in the model and
// the delegate hears it, a row the APP selects is shown in the native view, a reload changes the
// row count.  The app stays up a moment after the verdict, for a screenshot.
#import <Stdio.xc>
#if TABLE_ANDROID
#import "UXAndroidDriver.xc"
#else
#import "UXIosDriver.xc"
#endif
#import "UXWindow.xc"
#import "UXTableView.xc"

i32 gFails;

#if TABLE_ANDROID
extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_test_watchdog(i32 ms, i32 rc);
extern void ux_and_test_call_later(pointer fn, i32 ms);
extern i32 ux_and_test_table_rows(i32 handle, i32 node);
extern i32 ux_and_test_table_selected(i32 handle, i32 node, i32 row);
extern i32 ux_and_test_table_cell_is(i32 handle, i32 node, i32 row, i32 col, u8* want);
extern void ux_and_test_table_tap(i32 handle, i32 node, i32 row);
extern i32 ux_and_test_table_shown(i32 handle, i32 node);
extern void ux_and_test_table_row_at(i32 handle, i32 node, i32 row, i32* x, i32* y);
i32 tShown(i32 h, i32 n) { return ux_and_test_table_shown(h, n); }
i32 tRows(i32 h, i32 n) { return ux_and_test_table_rows(h, n); }
i32 tSelected(i32 h, i32 n, i32 r) { return ux_and_test_table_selected(h, n, r); }
i32 tCellIs(i32 h, i32 n, i32 r, i32 c, u8* w) { return ux_and_test_table_cell_is(h, n, r, c, w); }
void tTap(i32 h, i32 n, i32 r) { ux_and_test_table_tap(h, n, r); }
void tWatchdog(void) { ux_and_test_watchdog((i32)20000, (i32)2); }
void tLater(pointer fn, i32 ms) { ux_and_test_call_later(fn, ms); }
void tQuit(i32 rc) { ux_and_quit(rc); }
#else
extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);
extern void ux_ios_test_call_later(pointer fn, i32 ms);
extern i32 ux_ios_test_table_rows(i32 handle, i32 node);
extern i32 ux_ios_test_table_selected(i32 handle, i32 node, i32 row);
extern i32 ux_ios_test_table_cell_is(i32 handle, i32 node, i32 row, i32 col, u8* want);
extern void ux_ios_test_table_tap(i32 handle, i32 node, i32 row);
extern i32 ux_ios_test_table_shown(i32 handle, i32 node);
i32 tShown(i32 h, i32 n) { return ux_ios_test_table_shown(h, n); }
i32 tRows(i32 h, i32 n) { return ux_ios_test_table_rows(h, n); }
i32 tSelected(i32 h, i32 n, i32 r) { return ux_ios_test_table_selected(h, n, r); }
i32 tCellIs(i32 h, i32 n, i32 r, i32 c, u8* w) { return ux_ios_test_table_cell_is(h, n, r, c, w); }
void tTap(i32 h, i32 n, i32 r) { ux_ios_test_table_tap(h, n, r); }
void tWatchdog(void) { ux_ios_test_watchdog((i32)20000, (i32)2); }
void tLater(pointer fn, i32 ms) { ux_ios_test_call_later(fn, ms); }
void tQuit(i32 rc) { ux_ios_quit(rc); }
#endif
void finish(void)
    {
    tQuit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
void verdict(void)
    {
    Stdio.printf(gFails == (i32)0 ? "PASS: UXTableView is the platform's real table -- rows, cells, a tap into the model, app selection, reload, rows on screen\n" : "FAIL: %d\n", gFails);
    tLater((pointer)&finish, (i32)2500); // up a moment, for a screenshot
    }

void ck(u8* what, bool ok)
    {
    if (ok)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

class TableRows : Object<UXTableDataSource, UXTableDelegate>
    {
    i32 rows;
    i32 changes;
    i32 lastRow;
    void init(void)
        {
        rows = (i32)3;
        changes = (i32)0;
        lastRow = (i32)-1;
        }
    i32 numberOfRows(UXTableView* t)
        {
        return rows;
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        if (col == (i32)1)
            {
            return row == (i32)1 ? (u8*)"48 KB" : (u8*)"2 KB";
            }
        return row == (i32)0 ? (u8*)"notes.txt" : (row == (i32)1 ? (u8*)"sketch.png" : (u8*)"todo.md");
        }
    void tableSelectionDidChange(UXTableView* t, i32 row)
        {
        changes = changes + (i32)1;
        lastRow = row;
        }
    }

TableRows* gData;
UXTableView* gTable;
i32 gWinH;
i32 gNode;
i32 gChanges;
// After a REAL tap (the gate's adb input tap, on Android): the row the finger hit is selected.
void afterRealTap(void)
    {
    ck((u8*)"a REAL tap on the first row selects it", gTable.selectedRow == (i32)0 && gData.changes > gChanges);
    verdict();
    }
// After layout: the list really shows its rows (a data source gone by now would show none).
void afterLayout(void)
    {
    ck((u8*)"the native list shows its five rows", tShown(gWinH, gNode) == (i32)5);
#if TABLE_ANDROID
    i32 x = (i32)0;
    i32 y = (i32)0;
    ux_and_test_table_row_at(gWinH, gNode, (i32)0, &x, &y);
    gChanges = gData.changes;
    Stdio.printf("TAPAT %d %d\n", x, y);
    tLater((pointer)&afterRealTap, (i32)4000);
#else
    verdict();
#endif
    }

void testBody(void)
    {
    gFails = (i32)0;
    tWatchdog();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        tQuit((i32)1);
        return;
        }
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"table", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), content);
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    app.addWindow(win);
    TableRows* data = new TableRows();
    gData = data; // the table holds its data source weakly: keep it alive past this function
    UXTableView* table = new UXTableView();
    content.addSubview(table, UXGeom.make((i16)0, (i16)20, (i16)sw, (i16)300));
    table.addColumn((u8*)"Name", (i16)200);
    table.addColumn((u8*)"Size", (i16)100);
    table.setDataSource(data);
    table.setDelegate(data);
    table.reloadData();
    win.tree.finalise();
    win.displayAll();
    i32 h = win.handle;
    i32 n = (i32)table.index;

    ck((u8*)"a UITableView with the datasource's three rows", tRows(h, n) == (i32)3);
    ck((u8*)"...whose cells show the datasource's text", tCellIs(h, n, (i32)1, (i32)0, (u8*)"sketch.png") != (i32)0
       && tCellIs(h, n, (i32)1, (i32)1, (u8*)"48 KB") != (i32)0);
    tTap(h, n, (i32)1);
    ck((u8*)"a tapped row lands in the model", table.selectedRow == (i32)1);
    ck((u8*)"...and the delegate hears it", data.changes == (i32)1 && data.lastRow == (i32)1);
    table.selectRow((i32)2);
    win.displayAll();
    ck((u8*)"a row the app selects is shown natively", tSelected(h, n, (i32)2) == (i32)1 && tSelected(h, n, (i32)1) == (i32)0);
    data.rows = (i32)5;
    table.reloadData();
    win.displayAll();
    ck((u8*)"a reload changes the native row count", tRows(h, n) == (i32)5);
    gTable = table;
    gWinH = h;
    gNode = n;
    tLater((pointer)&afterLayout, (i32)800);
    }

void main(void)
    {
#if TABLE_ANDROID
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
#else
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
#endif
    }
