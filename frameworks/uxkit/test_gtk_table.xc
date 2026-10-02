// test_gtk_table.xc — UXTableView as a real GtkColumnView (run_gtk_linux.sh test_gtk_table; gate
// gtk-table): its rows and columns come from the table's own datasource; a row the USER selects in
// the native view lands in the model and the delegate hears it; a row the APP selects is pushed into
// the view without being echoed back; a reload changes the native row count.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXTableView.xc"

i32 ux_gtk_test_table_rows(i32 handle, i32 node);
i32 ux_gtk_test_table_selected(i32 handle, i32 node, i32 row);
void ux_gtk_test_table_user_select(i32 handle, i32 node, i32 row);
i32 ux_gtk_test_table_cell_is(i32 handle, i32 node, i32 row, i32 col, u8* want);
i32 ux_gtk_test_table_title_is(i32 handle, i32 node, i32 col, u8* want);
i32 ux_gtk_has_control(i32 handle, i32 node);

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
            return row == (i32)0 ? (u8*)"2 KB" : (row == (i32)1 ? (u8*)"48 KB" : (u8*)"1 KB");
            }
        if (row == (i32)0)
            {
            return (u8*)"notes.txt";
            }
        if (row == (i32)1)
            {
            return (u8*)"sketch.png";
            }
        if (row == (i32)2)
            {
            return (u8*)"todo.md";
            }
        return (u8*)"more.txt";
        }
    void tableSelectionDidChange(UXTableView* t, i32 row)
        {
        changes = changes + (i32)1;
        lastRow = row;
        }
    }

void main(void)
    {
    gFails = (i32)0;
    UXGtkDriver* d = new UXGtkDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no GTK display\n");
        return;
        }
    UXApplication* app = new UXApplication();
    app.setDriver((UXViewDriver*)d);
    gApp = app;
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"table", UXGeom.make((i16)0, (i16)0, (i16)320, (i16)200), content);
    app.addWindow(win);
    Data* data = new Data();
    UXTableView* table = new UXTableView();
    content.addSubview(table, UXGeom.make((i16)10, (i16)10, (i16)300, (i16)180));
    table.addColumn((u8*)"Name", (i16)180);
    table.addColumn((u8*)"Size", (i16)80);
    table.setDataSource(data);
    table.setDelegate(data);
    table.reloadData();
    win.tree.finalise();
    win.displayAll();
    i32 h = win.handle;
    i32 n = (i32)table.index;

    ck((u8*)"the table is a native widget", ux_gtk_has_control(h, n) != (i32)0);
    ck((u8*)"...with the datasource's three rows", ux_gtk_test_table_rows(h, n) == (i32)3);
    ck((u8*)"...its columns' titles", ux_gtk_test_table_title_is(h, n, (i32)0, (u8*)"Name") != (i32)0 && ux_gtk_test_table_title_is(h, n, (i32)1, (u8*)"Size") != (i32)0);
    ck((u8*)"...and its cells' text", ux_gtk_test_table_cell_is(h, n, (i32)1, (i32)0, (u8*)"sketch.png") != (i32)0 && ux_gtk_test_table_cell_is(h, n, (i32)1, (i32)1, (u8*)"48 KB") != (i32)0);

    ux_gtk_test_table_user_select(h, n, (i32)1);
    ck((u8*)"a row the user selects lands in the model", table.selectedRow == (i32)1);
    ck((u8*)"...and the delegate hears it", data.changes == (i32)1 && data.lastRow == (i32)1);

    i32 before = data.changes;
    table.selectRow((i32)2);
    win.displayAll();
    ck((u8*)"a row the app selects is shown in the native view", ux_gtk_test_table_selected(h, n, (i32)2) == (i32)1 && ux_gtk_test_table_selected(h, n, (i32)1) == (i32)0);
    ck((u8*)"...without echoing back as a user change", data.changes - before <= (i32)1);

    data.rows = (i32)5;
    table.reloadData();
    win.displayAll();
    ck((u8*)"a reload changes the native row count", ux_gtk_test_table_rows(h, n) == (i32)5);

    win.close();
    Stdio.printf(gFails == (i32)0 ? "PASS: UXTableView is a real GtkColumnView -- rows, titles, cells, selection both ways, reload\n" : "FAIL: %d\n", gFails);
    }
