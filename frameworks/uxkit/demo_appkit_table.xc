// demo_appkit_table.xc — a native NSTableView, driven by the neutral UXTableView datasource.
//
// The SAME datasource that materialises a GEM row/cell object tree (test_table) drives a real
// macOS NSTableView here: native column headers, alternating rows, native selection + scrolling.
// A row click routes back through UXTableView.selectRow, so the app's tableSelectionDidChange fires
// unchanged and updates a label.  Nothing in the app is AppKit-aware except the driver.
//
//   Build+run:  make appkit-table   (macOS; click a row, scroll the list)
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXTableView.xc"
#import "UXString.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"
#import "demo_autoquit.xc" // UX_AUTOQUIT: let a sweep run this unattended

#define NROWS 8

// The datasource owns the data; the table (and the native NSTableView) only ask for it.
// Static strings: the pointer valueForCell returns is read directly by the native cell, uncopied.
u8* gName[NROWS];
u8* gSize[NROWS];
u8* gKind[NROWS];

// A plain container: paints a backdrop so the native table + labels sit on a window, nothing more.
class Canvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)0, (i16)0, (i16)380, (i16)280), (i32)8); // grey backdrop
        }
    }

    class Data : Object<UXTableDataSource, UXTableDelegate>
    {
    weak : UXLabel* status;
    void init(void)
        {
        status = (UXLabel*)0;
        }

    i32 numberOfRows(UXTableView* t)
        {
        return (i32)NROWS;
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        if (row < (i32)0 || row >= (i32)NROWS)
            {
            return (u8*)"";
            }
        if (col == (i32)0)
            {
            return gName[row];
            }
        if (col == (i32)1)
            {
            return gSize[row];
            }
        return gKind[row];
        }
    void tableSelectionDidChange(UXTableView* t, i32 row)
        {
        if (status == (UXLabel*)0)
            {
            return;
            }
        i32 n = t.selectedCount();
        if (n == (i32)0)
            {
            status.setText((u8*)"(nothing selected)");
            }
        else if (n == (i32)1)
            {
            status.setText(gName[row]);
            }
        else
            {
            status.setText(UXStr.append(UXStr.fromInt(n), (u8*)" rows selected"));
            }
        Stdio.printf("selection: %d row(s), anchor %d\n", (i16)n, (i16)row);
        }
    }

    class Ctl : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    UXTableView* table;
    Data* data;

    i32 applicationDidStart(UXApplication* a)
        {
        gName[0] = (u8*)"README.md";
        gSize[0] = (u8*)"2 KB";
        gKind[0] = (u8*)"Markdown";
        gName[1] = (u8*)"main.xc";
        gSize[1] = (u8*)"14 KB";
        gKind[1] = (u8*)"Source";
        gName[2] = (u8*)"UXWindow.xc";
        gSize[2] = (u8*)"9 KB";
        gKind[2] = (u8*)"Source";
        gName[3] = (u8*)"logo.png";
        gSize[3] = (u8*)"48 KB";
        gKind[3] = (u8*)"Image";
        gName[4] = (u8*)"notes.txt";
        gSize[4] = (u8*)"1 KB";
        gKind[4] = (u8*)"Text";
        gName[5] = (u8*)"build.sh";
        gSize[5] = (u8*)"512 B";
        gKind[5] = (u8*)"Script";
        gName[6] = (u8*)"data.json";
        gSize[6] = (u8*)"22 KB";
        gKind[6] = (u8*)"JSON";
        gName[7] = (u8*)"Makefile";
        gSize[7] = (u8*)"3 KB";
        gKind[7] = (u8*)"Makefile";

        data = new Data();
        Canvas* canvas = new Canvas();
        win = new UXWindow();
        win.open((u8*)"UXKit — native table", UXGeom.make((i16)160, (i16)160, (i16)380, (i16)280), canvas);
        a.addWindow(win);

        UXLabel* head = new UXLabel();
        head.setText((u8*)"Native NSTableView — cmd-click to toggle, shift-click to extend:");
        canvas.addSubview(head, UXGeom.make((i16)12, (i16)10, (i16)356, (i16)16));

        // The table is shorter than its 8 rows need, so the native table shows its own scroller.
        table = new UXTableView();
        canvas.addSubview(table, UXGeom.make((i16)12, (i16)34, (i16)356, (i16)190));
        table.setAllowsMultipleSelection(true);
        table.setRowHeight((i16)18);
        table.addColumn((u8*)"Name", (i16)170);
        table.addColumn((u8*)"Size", (i16)70);
        table.addColumn((u8*)"Kind", (i16)110);
        table.setDataSource(data);
        table.setDelegate(data);
        table.reloadData();

        UXLabel* status = new UXLabel();
        status.setText((u8*)"(nothing selected)");
        canvas.addSubview(status, UXGeom.make((i16)12, (i16)232, (i16)356, (i16)16));
        data.status = status;

        win.tree.finalise();
        win.displayAll();
        Stdio.printf("table demo up — %d rows, click one; the label shows the selection\n", (i16)NROWS);
        return (i32)0;
        }
    } void main(void)
    {
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true);
    Ctl* c = new Ctl();
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    app.setDelegate(c);
    uxAutoQuit();
    app.run();
    }
