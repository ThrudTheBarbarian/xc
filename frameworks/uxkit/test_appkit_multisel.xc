// test_appkit_multisel.xc — the neutral multi-selection model, exercised headless.
//
// Selection lives in each row object's state, so the "set" is however many rows carry it — there is
// no separate list to fall out of step.  This drives the neutral UXTableView selection ops directly
// (no GUI, no run loop) and reads the set back: plain select replaces, ctrl toggles, shift extends a
// range, and applyNativeSelection adopts a set the native backend already made.  All backend-neutral.
//
//   Build+run:  sh run_appkit_multisel.sh   (xtc -A arm64 + the ObjC shim, native; no window shown)
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXTableView.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

#define NROWS 8

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
i32 b(bool v)
    {
    return v ? (i32)1 : (i32)0;
    }

class Data : Object<UXTableDataSource>
    {
    void init(void)
        {
        }
    i32 numberOfRows(UXTableView* t)
        {
        return (i32)NROWS;
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        return (u8*)"x";
        }
    }

    class Del : Object<UXApplicationDelegate>
    {
    UXTableView* table;

    i32 applicationDidStart(UXApplication* app)
        {
        gFails = (i32)0;
        UXWindow* win = new UXWindow();
        UXView* content = new UXView();
        win.open((u8*)"t", UXGeom.make((i16)40, (i16)40, (i16)220, (i16)140), content);
        app.addWindow(win);

        Data* data = new Data();
        table = new UXTableView();
        content.addSubview(table, UXGeom.make((i16)8, (i16)8, (i16)200, (i16)120));
        table.setAllowsMultipleSelection(true);
        table.addColumn((u8*)"C", (i16)180);
        table.setDataSource(data);
        table.reloadData();

        check("multi flag on", b(table.allowsMultipleSelection()), (i32)1);
        check("initial selection is empty", table.selectedCount(), (i32)0);

        // plain select -> exactly one row
        table.selectRow((i32)2);
        check("selectRow(2): count", table.selectedCount(), (i32)1);
        check("selectRow(2): row 2 set", b(table.isRowSelected((i32)2)), (i32)1);

        // ctrl-toggle a second row IN, keeping the first (anchor follows to 5)
        table.toggleRow((i32)5);
        check("toggle 5 in: count", table.selectedCount(), (i32)2);
        check("toggle 5 in: row 2 kept", b(table.isRowSelected((i32)2)), (i32)1);
        check("toggle 5 in: anchor", table.selection(), (i32)5);

        // shift-extend from the anchor (5) down to 2 -> {2,3,4,5}, dropping the rest
        table.extendSelectionTo((i32)2);
        check("extend 5..2: count", table.selectedCount(), (i32)4);
        check("extend 5..2: row 3 in", b(table.isRowSelected((i32)3)), (i32)1);
        check("extend 5..2: row 5 in", b(table.isRowSelected((i32)5)), (i32)1);
        check("extend 5..2: row 6 out", b(table.isRowSelected((i32)6)), (i32)0);

        // a plain click collapses the whole set to one row
        table.selectRow((i32)0);
        check("selectRow(0) collapses: count", table.selectedCount(), (i32)1);
        check("selectRow(0) collapses: row 5 gone", b(table.isRowSelected((i32)5)), (i32)0);

        // adopt a native set: exactly {1,3,6}, anchor on the last
        i32 want[3];
        want[0] = (i32)1;
        want[1] = (i32)3;
        want[2] = (i32)6;
        table.applyNativeSelection(&want[0], (i32)3);
        check("applyNative: count", table.selectedCount(), (i32)3);
        check("applyNative: anchor is last", table.selection(), (i32)6);

        // ctrl-toggle one of them back OUT
        table.toggleRow((i32)3);
        check("toggle 3 out: count", table.selectedCount(), (i32)2);
        check("toggle 3 out: row 3 gone", b(table.isRowSelected((i32)3)), (i32)0);

        // read the set back, ascending
        i32 got[8];
        i32 n = table.selectedRows(&got[0], (i32)8);
        check("selectedRows: n", n, (i32)2);
        check("selectedRows[0]", got[0], (i32)1);
        check("selectedRows[1]", got[1], (i32)6);

        ux_ak_post_quit();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    gDriver = new UXAppKitDriver();
    Del* del = new Del();
    UXApplication* app = new UXApplication();
    app.setDelegate(del);
    app.run();
    Stdio.printf(gFails == (i32)0
                     ? "PASS: the neutral multi-selection model (replace / toggle / extend / adopt) is correct\n"
                     : "FAIL: %d multi-selection checks failed\n",
                 (i16)gFails);
    }
