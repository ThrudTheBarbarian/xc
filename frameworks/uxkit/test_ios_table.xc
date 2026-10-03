// test_ios_table.xc — UXTableView as a real UITableView on iOS (the ios-table gate): rows and
// cells from the table's own datasource, a row the USER taps lands in the model and the delegate
// hears it, a row the APP selects is shown in the native view, a reload changes the row count.
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXWindow.xc"
#import "UXTableView.xc"

extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);
extern i32 ux_ios_test_table_rows(i32 handle, i32 node);
extern i32 ux_ios_test_table_selected(i32 handle, i32 node, i32 row);
extern i32 ux_ios_test_table_cell_is(i32 handle, i32 node, i32 row, i32 col, u8* want);
extern void ux_ios_test_table_tap(i32 handle, i32 node, i32 row);

i32 gFails;
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

class Data : Object<UXTableDataSource, UXTableDelegate>
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

void testBody(void)
    {
    gFails = (i32)0;
    ux_ios_test_watchdog((i32)20000, (i32)2);
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        ux_ios_quit((i32)1);
        return;
        }
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"table", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), content);
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    app.addWindow(win);
    Data* data = new Data();
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

    ck((u8*)"a UITableView with the datasource's three rows", ux_ios_test_table_rows(h, n) == (i32)3);
    ck((u8*)"...whose cells show the datasource's text", ux_ios_test_table_cell_is(h, n, (i32)1, (i32)0, (u8*)"sketch.png") != (i32)0
       && ux_ios_test_table_cell_is(h, n, (i32)1, (i32)1, (u8*)"48 KB") != (i32)0);
    ux_ios_test_table_tap(h, n, (i32)1);
    ck((u8*)"a tapped row lands in the model", table.selectedRow == (i32)1);
    ck((u8*)"...and the delegate hears it", data.changes == (i32)1 && data.lastRow == (i32)1);
    table.selectRow((i32)2);
    win.displayAll();
    ck((u8*)"a row the app selects is shown natively", ux_ios_test_table_selected(h, n, (i32)2) == (i32)1 && ux_ios_test_table_selected(h, n, (i32)1) == (i32)0);
    data.rows = (i32)5;
    table.reloadData();
    win.displayAll();
    ck((u8*)"a reload changes the native row count", ux_ios_test_table_rows(h, n) == (i32)5);
    Stdio.printf(gFails == (i32)0 ? "PASS: UXTableView is a real UITableView -- rows, cells, a tap into the model, app selection, reload\n" : "FAIL: %d\n", gFails);
    ux_ios_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }

void main(void)
    {
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
    }
