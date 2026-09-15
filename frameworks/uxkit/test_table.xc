// test_table.xc — a table view, driven by a datasource, scrolled by the AES.
//
// The claims under test, in order of how much they matter:
//
//   1. The table asks a DATASOURCE for its contents.  It holds no data.
//   2. Rows and cells are REAL GEM OBJECTS — so objc_draw draws them, objc_find finds
//      them, and none of that is code in Xtg.
//   3. A click on a CELL selects its ROW, because the cell does not handle the click and
//      the responder chain carries it up.  That is the chain doing its job, not a
//      special case.
//   4. Selection lives in the OBJECT's ob_state, so it survives a redraw.
//   5. Selecting damages TWO ROWS — the old one and the new one — not the table.
//   6. Scroll, and a click at a fixed screen point hits a DIFFERENT row, with no
//      arithmetic anywhere, because the tree really moved.

#import <Stdio.xc>
#import <GEM>
#import "UXGem.xc"
#import "UXBoot.xc"
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXWindow.xc"
#import "UXTableView.xc"

#define NROWS 30
#define ROW_H 16

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

// The datasource.  It owns the data; the table only asks.
// (Static strings: valueForCell's pointer goes straight into ob_spec, uncopied.)
u8* gNames[NROWS];
u8* gKinds[NROWS];

class Data : Object<UXTableDataSource, UXTableDelegate>
    {
    i32 changes;
    i32 lastRow;
    void init(void)
        {
        changes = (i32)0;
        lastRow = (i32)-1;
        }

    i32 numberOfRows(UXTableView* t)
        {
        return (i32)NROWS;
        }

    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        if (col == (i32)0)
            {
            return gNames[row];
            }
        return gKinds[row];
        }

    void tableSelectionDidChange(UXTableView* t, i32 row)
        {
        changes = changes + (i32)1;
        lastRow = row;
        }
    }

    class Controller : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    UXTableView* table;
    Data* data;
    void init(void)
        {
        }

    i32 applicationDidStart(UXApplication* a)
        {
        gFails = (i32)0;
        for (i32 i = (i32)0; i < (i32)NROWS; i++)
            {
            gNames[i] = "row";
            gKinds[i] = "folder";
            }

        data = new Data();
        table = new UXTableView();
        win = new UXWindow();
        a.addWindow(win);
        win.open("Table", UXGeom.make((i16)4, (i16)4, (i16)180, (i16)100), table);

        table.setRowHeight((i16)ROW_H);
        table.addColumn("Name", (i16)90);
        table.addColumn("Kind", (i16)60);
        table.setDataSource(data);
        table.setDelegate(data);

        // ---- 1. the table asks the datasource ------------------------------
        table.reloadData();
        check("rows, from the datasource", table.rowCount(), (i32)NROWS);
        check("columns", table.numberOfColumns(), (i32)2);

        // ---- 2. rows and cells are REAL GEM OBJECTS -------------------------
        // 1 table root + NROWS rows + NROWS*2 cells.
        i32 objs = (i32)win.tree.length();
        Stdio.printf("the tree holds %d objects (1 root + %d rows + %d cells)\n",
                     (i16)objs, (i16)NROWS, (i16)(NROWS * (i32)2));
        check("every row and cell is a GEM object", objs, (i32)1 + (i32)NROWS * (i32)3);

        // ---- the table is taller than the window: the AES gets a scrollbar --
        win.setContentSize((i16)150, table.contentHeight());
        win.tree.finalise();
        win.displayAll();
        a.pump((i32)200); // gemd's answer (the narrowed work area) arrives here

        i32 wx = (i32)0;
        i32 wy = (i32)0;
        i32 ww = (i32)0;
        i32 wh = (i32)0;
        wind_get(win.handle, (i32)WF_WORKXYWH, &wx, &wy, &ww, &wh);
        Stdio.printf("%d rows x %dpx = %dpx of content in a %dpx work area\n",
                     (i16)NROWS, (i16)ROW_H, (i16)table.contentHeight(), (i16)wh);

        // ---- 3. a click on a CELL selects its ROW ---------------------------
        // Aim at row 2's first cell.  objc_find returns the deepest object under the
        // point — the CELL — and the cell does not handle mouseDown, so the responder
        // chain carries it to the row, which selects itself.
        i32 cy = wy + (i32)2 * (i32)ROW_H + (i32)(ROW_H / 2);
        i32 hit = win.tree.hitTest((i16)(wx + (i32)10), (i16)cy);
        Stdio.printf("click inside row 2's first cell -> object %d\n", (i16)hit);

        UXView* v = (UXView* ?)win.tree.viewAt((u16)hit);
        UXEvent* e = new UXEvent();
        e.kind = (u8)UXEventMouseDown;
        e.x = (i16)(wx + (i32)10);
        e.y = (i16)cy;
        v.mouseDown(e); // dispatch exactly as the run loop would

        check("the click selected row 2", table.selection(), (i32)2);
        check("the delegate was told", data.changes, (i32)1);
        check("...and told WHICH row", data.lastRow, (i32)2);

        // ---- 4. selection lives in the OBJECT ------------------------------
        UXTableRow* r2 = (UXTableRow* ?)table.rows.get((u16)2);
        bool sel = (((OBJECT*)win.tree.objects())[r2.index].ob_state & (u16)OS_SELECTED) != (u16)0;
        check("OS_SELECTED is set on the row OBJECT", sel ? (i32)1 : (i32)0, (i32)1);

        // ---- 5. selecting damages TWO ROWS, not the table -------------------
        win.display(); // flush the damage from the click
        table.selectRow((i32)5);
        UXRect d = win.tree.dirty;
        Stdio.printf("selecting row 5 damaged %d,%d %dx%d\n",
                     (i16)d.x, (i16)d.y, (i16)d.w, (i16)d.h);
        // rows 2..5 inclusive: the union of the old row and the new one.
        check("the damage is 4 rows tall, not the whole table",
              (i32)d.h, (i32)4 * (i32)ROW_H);
        check("...and not the table's full height", (i32)d.h < (i32)table.contentHeight() ? (i32)1 : (i32)0, (i32)1);

        // ---- 6. scroll, and the SAME screen point hits a DIFFERENT row -------
        i32 before = win.tree.hitTest((i16)(wx + (i32)10), (i16)(wy + (i32)2));
        win.scrollTo((i16)0, (i16)(4 * ROW_H)); // down exactly four rows
        win.displayAll();
        i32 after = win.tree.hitTest((i16)(wx + (i32)10), (i16)(wy + (i32)2));
        Stdio.printf("the same point hit object %d, now hits %d (scrolled 4 rows)\n",
                     (i16)before, (i16)after);
        // Row N's first cell is at object 1 + N*3 + 1. Row 0 -> 2, row 4 -> 14.
        check("before the scroll, the top row is row 0", before, (i32)2);
        check("after scrolling 4 rows, the top row is row 4", after, (i32)14);

        // ---- 7. HOW DOES IT SCALE? -------------------------------------------
        // 30 rows exist as objects, but only ~4 fit in a 64px work area.  A row that is
        // scrolled out of sight carries OF_CLIPCHILDREN and misses the clip, so the AES
        // prunes it BEFORE drawing it — it is never visited, and neither are its 2 cells.
        // So a full repaint should call back into ~5 rows, not 30, and the cost of a
        // repaint is set by what is VISIBLE, not by how much data there is.
        table.drawCount = (i32)0;
        win.displayAll();
        i32 visible = (i32)wh / (i32)ROW_H;
        Stdio.printf("full repaint of a %d-row table: the AES called back into %d rows\n",
                     (i16)NROWS, (i16)table.drawCount);
        Stdio.printf("  (%d rows fit in the %dpx work area)\n", (i16)visible, (i16)wh);
        if (table.drawCount <= visible + (i32)2)
            {
            Stdio.printf("  ok   the repaint costs the VISIBLE rows, not the %d that exist\n", (i16)NROWS);
            }
        else
            {
            Stdio.printf("  FAIL the AES walked %d rows to paint %d\n",
                         (i16)table.drawCount, (i16)visible);
            gFails = gFails + (i32)1;
            }

        if (gFails == (i32)0)
            {
            Stdio.printf("PASS: a datasource-driven table of real GEM objects.  GEM draws the\n");
            Stdio.printf("      cells, objc_find hit-tests them, the responder chain routes the\n");
            Stdio.printf("      click to the row, and the AES scrolls it.  Xtg draws ONE RECT.\n");
            }
        else
            {
            Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
            }
        a.stop();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }
    gDriver = new UXGemDriver(); // select the GEM backend (UXApplication is neutral)
    UXApplication* app = new UXApplication();
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run();
    }
