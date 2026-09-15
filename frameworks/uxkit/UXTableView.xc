// UXTableView.xc — a table, as a datasource and a tree of real GEM objects.
//
// The AppKit split, kept: the table does not hold your data, it ASKS for it.  You
// implement two methods and the table does the rest.
//
//     protocol UXTableDataSource {
//         i32 numberOfRows(UXTableView* t);
//         u8* valueForCell(UXTableView* t, i32 row, i32 col);
//     }
//
// WHAT THIS FILE DOES NOT CONTAIN, and why:
//
//   no scrollbar       the AES owns it.  The table reports its height (contentHeight)
//                      and the window hands that to wind_content_size; gemd then draws a
//                      themed bar, runs the thumb, the wheel and the arrows, narrows the
//                      work area to fit it, and clamps the offset.  See test_scroll.
//
//   no hit-testing     objc_find does it.  Because a scrolled tree really has moved, a
//                      click on a scrolled row lands on that row with no arithmetic.
//
//   no text drawing    a cell IS a G_STRING, so GEM draws it, in the themed font.
//
//   no click routing   a cell does not override mouseDown, so the responder chain carries
//                      the click up to its row, which is what makes the ROW the selectable
//                      thing even though the CELL is what got hit.
//
// What it DOES draw is one filled rectangle, for the selected row — and that is drawn
// because a table row is CONTENT, not chrome.  (A themed "list.row.selected" slice would
// be better still, and would move even this out of Xtg.  There isn't one yet.)
//
// LIFETIME: valueForCell returns a pointer that goes straight into ob_spec, and GEM reads
// it on every draw.  The strings must outlive the table — a literal, or a buffer the
// datasource owns.  Nothing is copied.

#import "UXGem.xc"
#import "UXView.xc"
#import "UXEvent.xc"
#import "UXIndexSet.xc" // a selection IS an index set — the announcement carries one
#import "UXGraphics.xc"
#import "UXApplication.xc" // gApp — to repaint mid drag-track (the run loop is blocked then)
#import "UXScrollView.xc"  // the table sits in one: it owns the clip/scroll/bar; the table the data

// No forward declaration: a protocol may name a class defined later in the file (which is
// how UXApplicationDelegate names UXApplication), and xtc has no `class X;` form.
protocol UXTableDataSource
    {
    i32 numberOfRows(UXTableView * t);
    u8* valueForCell(UXTableView * t, i32 row, i32 col);
    }

protocol UXTableDelegate
    {
    optional void tableSelectionDidChange(UXTableView * t, i32 row);
    }

// The type of that optional method, so it can be taken as a `callback` and tested.
// A column: a title and a width.  Nothing else — the table lays cells out from these.
class UXTableColumn : Object
    {
    u8* title;
    i16 width;
    void init(void)
        {
        title = "";
        width = (i16)80;
        }
    }

    // A cell.  A G_STRING, so GEM draws the text and we write nothing.  It deliberately does
    // NOT override mouseDown: the click bubbles up the responder chain to the row.
    // A cell.  Custom-drawn (UXKindView) so the backends that paint the table themselves (GEM) control
    // the font size + vertical centring — the AES's stock G_STRING is a fixed 14px, which reads small in
    // a list.  Win32/AppKit render the table natively and never draw this.
    class UXTableCell : UXView
    {
    u8* text;
    void init(void)
        {
        super.init();
        text = (u8*)0;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        if (text == (u8*)0)
            {
            return;
            }
        i16 fh = (i16)(self.bounds().h - (i16)6); // font scales with the row (a roomy cell)
        // ...but never smaller than the AES's stock
        if (fh < (i16)13)
            {
            fh = (i16)13;
            }
        i16 ty = (i16)((self.bounds().h - fh) / (i16)2); // vertically centred in the row
        g.drawText(text, (i16)4, ty, (i32)1, (i32)fh);
        }
    }

    // A row.  A G_USERDEF, because the one thing GEM will not draw for us is the selection
    // highlight (no object type honours OS_SELECTED with a background fill).
    class UXTableRow : UXView
    {
    weak : UXTableView* table; // weak: the table owns the tree that owns us
    i32 row;

    void init(void)
        {
        super.init();
        table = (UXTableView*)0;
        row = (i32)0;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }

    // The selected background — the whole of this class's drawing.  The cells are
    // G_STRINGs and GEM draws them on top of this, because draw_rec paints an object
    // before it recurses into that object's children.  Pen 8 is light grey, so the
    // cells' black text stays readable on it without our touching the text at all.
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        if (table != (UXTableView*)0)
            {
            table.drawCount = table.drawCount + (i32)1;
            }
        if (!self.isSelected())
            {
            return;
            }
        g.fillRect(self.bounds(), (i32)UX_PEN_SELECT); // bounds: UXGraphics converts
        }

    bool isSelected(void)
        {
        return owner.selectedOf(index);
        }

    // A click selects the row.  With multi-select on, the modifiers decide (as every list does):
    // ctrl toggles this row into/out of the set, shift extends from the anchor, a plain click
    // replaces.  AppKit's native NSTableView does this itself and never routes through here.
    void mouseDown(UXEvent* e)
        {
        if (table == (UXTableView*)0)
            {
            return;
            }
        // Modifier clicks are discrete (no drag): ctrl toggles this row, shift extends from the anchor.
        if (table.allowsMultipleSelection() && (e.modifiers & (u16)UX_MOD_CTRL) != (u16)0)
            {
            table.toggleRow(row);
            return;
            }
        if (table.allowsMultipleSelection() && (e.modifiers & (u16)UX_MOD_SHIFT) != (u16)0)
            {
            table.extendSelectionTo(row);
            return;
            }
        // A plain press selects this row (the anchor), then tracks a drag to sweep a range/selection.
        table.selectRow(row);
        table.beginDragSelect();
        }
    }

    // The column-title header, drawn ABOVE the rows on the backends that paint the table themselves
    // (GEM; Win32/AppKit use their native header instead and hide this subtree).  It draws the titles at
    // each column's x with a rule beneath — the same data the rows read.
    class UXTableHeader : UXView
    {
    weak : UXTableView* table;
    void init(void)
        {
        super.init();
        table = (UXTableView*)0;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        if (table == (UXTableView*)0)
            {
            return;
            }
        UXRect b = self.bounds();
        g.fillRect(b, (i32)9); // darker grey: a header strip that
                               // reads as chrome, not the pen-8 window
        i32 ncol = table.numberOfColumns();
        i16 cx = (i16)4;
        i16 fh = (i16)(b.h - (i16)6);
        if (fh < (i16)13)
            {
            fh = (i16)13;
            }
        i16 ty = (i16)((b.h - fh) / (i16)2);
        for (i32 c = (i32)0; c < ncol; c = c + (i32)1)
            {
            g.drawText(table.columnTitle(c), cx, ty, (i32)1, (i32)fh); // black title, matches cells
            cx = (i16)(cx + table.columnWidth(c));
            }
        g.drawLine((i16)0, (i16)(b.h - (i16)1), b.w, (i16)(b.h - (i16)1), (i32)1); // rule under the header
        }
    }

    class UXTableView : UXView
    {
    weak : UXTableDataSource* dataSource;
    weak : UXTableDelegate* delegate;

    Array<UXTableColumn>* columns; // UXTableColumn
    Array<UXTableRow>* rows;       // UXTableRow, one per row currently materialised
    UXTableHeader* header;         // the column-title strip (GEM/Win32-box path; native tables ignore it)
    UXScrollView* scroll;          // the scroller the table sits in: header pinned, rows in its document (GEM
                                   // path).  It owns clipping + the bar + wheel/arrows/thumb; the table the data.
    bool nativeReload;             // rows changed since the native control was last filled
    bool nativeSelDirty;           // the MODEL's selection moved (replay, app code): push it to the control
    i16 headerH;                   // its height; rows start below it
    i16 rowHeight;
    i32 selectedRow;     // the anchor row: -1 = none, else the last row clicked (shift extends from it)
    bool allowsMultiple; // off: one row at a time; on: ctrl toggles, shift extends a range
    i32 nrows;

    // How many rows the AES actually called back into.  This is the scaling number: a row
    // that is scrolled out of sight is pruned by OF_CLIPCHILDREN *before* draw_obj runs, so
    // it is never visited at all, and neither are its cells.  One i32 buys the ability to
    // MEASURE that instead of believing it — see test_table.
    i32 drawCount;

    // How many row objects EXIST.  >= nrows: the surplus is hidden, not deleted.
    i32 builtRows;

    void init(void)
        {
        super.init();
        dataSource = (UXTableDataSource*)0;
        delegate = (UXTableDelegate*)0;
        columns = new Array();
        rows = new Array();
        header = (UXTableHeader*)0;
        scroll = (UXScrollView*)0;
        nativeReload = false;
        nativeSelDirty = false;
        headerH = (i16)20;
        rowHeight = (i16)16;
        selectedRow = (i32)-1;
        allowsMultiple = false;
        nrows = (i32)0;
        drawCount = (i32)0;
        builtRows = (i32)0;
        }

    // UXKindTable: GEM/Win32 paint it as a box and draw the row/cell subtree (below); AppKit
    // overlays a native NSTableView driven straight from this object (see attachTo's peer).
    UXKind kind(void)
        {
        return UXKindTable;
        }

    // Hand this object to the driver as the node's peer.  A backend that overlays a native table
    // (AppKit) reads rows/columns/selection from it; GEM/Win32 ignore it (no-op) and render the
    // subtree.  Set after super.attachTo, so `index`/`owner` are live.
    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        t.setPeerOf(index, (pointer)self);
        t.setClipsOf(index, true);
        // The scroller fills the table and does all the scrolling (clip + bar + wheel/arrows/thumb).
        // On AppKit/win32 the native table overlays this whole subtree, so it only shows on GEM.
        scroll = new UXScrollView();
        self.addSubview(scroll, UXGeom.make((i16)0, (i16)0, frame.w, frame.h));
        scroll.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        scroll.setLineHeight(rowHeight);
        }

    // ---- native-overlay bridge (a driver's NSTableView datasource reads these) -------
    // A native table pulls the same data the GEM subtree does — row count and cell strings from the
    // datasource, titles/widths from the columns — so one datasource drives every backend.
    i32 nativeRowCount(void)
        {
        return self.countRows();
        }
    u8* nativeCellText(i32 row, i32 col)
        {
        if (dataSource == (UXTableDataSource*)0)
            {
            return (u8*)"";
            }
        return dataSource.valueForCell(self, row, col);
        }
    u8* columnTitle(i32 c)
        {
        if (c < (i32)0 || c >= (i32)columns.count())
            {
            return (u8*)"";
            }
        return ((UXTableColumn* ?)columns.get((u16)c)).title;
        }
    i16 columnWidth(i32 c)
        {
        if (c < (i32)0 || c >= (i32)columns.count())
            {
            return (i16)80;
            }
        return ((UXTableColumn* ?)columns.get((u16)c)).width;
        }
    i32 nativeAllowsMultiple(void)
        {
        return allowsMultiple ? (i32)1 : (i32)0;
        }
    // A native backend asks this to choose a native TREE control over a flat list.  A plain table is
    // not an outline; UXOutlineView overrides it and answers the item hooks below.
    i32 nativeIsOutline(void)
        {
        return (i32)0;
        }

    void setDataSource(UXTableDataSource* d)
        {
        dataSource = d;
        }
    void setDelegate(UXTableDelegate* d)
        {
        delegate = d;
        }
    void setRowHeight(i16 h)
        {
        rowHeight = h;
        }
    i16 rowHeightValue(void)
        {
        return rowHeight;
        }
    i32 numberOfColumns(void)
        {
        return (i32)columns.count();
        }
    i32 rowCount(void)
        {
        return nrows;
        }
    i32 selection(void)
        {
        return selectedRow;
        }

    // ---- multi-selection ------------------------------------------------------
    // Selection state lives in each row object (OS_SELECTED), so the set is however many rows carry
    // it — no separate list to keep in step.  allowsMultiple only gates how a click builds it.
    void setAllowsMultipleSelection(bool on)
        {
        allowsMultiple = on;
        }
    bool allowsMultipleSelection(void)
        {
        return allowsMultiple;
        }

    bool isRowSelected(i32 r)
        {
        if (r < (i32)0 || r >= nrows)
            {
            return false;
            }
        return owner.selectedOf(((UXTableRow* ?)rows.get((u16)r)).index);
        }
    i32 selectedCount(void)
        {
        i32 n = (i32)0;
        for (i32 r = (i32)0; r < nrows; r++)
            {
            if (self.isRowSelected(r))
                {
                n = n + (i32)1;
                }
            }
        return n;
        }
    // Fill out[0..max) with the selected row indices (ascending); return how many there are.
    i32 selectedRows(i32* out, i32 max)
        {
        i32 n = (i32)0;
        for (i32 r = (i32)0; r < nrows; r++)
            {
            if (self.isRowSelected(r))
                {
                if (n < max)
                    {
                    out[n] = r;
                    }
                n = n + (i32)1;
                }
            }
        return n;
        }

    void addColumn(u8* title, i16 width)
        {
        UXTableColumn* c = new UXTableColumn();
        c.title = title;
        c.width = width;
        columns.add(c);
        }

    // How tall the table really is.  The window hands this to setContentSize, and the
    // AES turns it into a scrollbar.  (The table cannot reach the window itself — an
    // UXView -> UXWindow import would be a cycle — so the app wires the two together.)
    i16 contentHeight(void)
        {
        return (i16)((i32)nrows * (i32)rowHeight);
        }

    // Scrolling lives in the UXScrollView the table sits in (clip + bar + wheel/arrows/thumb): the
    // rows are its document, sized to nrows*rowHeight, and it moves the document under a pinned header.

    // ---- the three hooks a subclass overrides --------------------------------
    // UXOutlineView is a table whose row list is DERIVED from a tree, so it needs to say
    // how many rows there are, what class a row is, and what goes in the cells.  Nothing
    // else about a table changes — which is why an outline gets scrolling, hit-testing,
    // selection and pruning without a line of new code for any of them.
    //
    // Always called through `self.` — a bare self-call is devirtualised by xtc today
    // (spikes/XTC-BUGS.md, bug B) and would silently run THIS implementation, not the
    // override.

    i32 countRows(void)
        {
        if (dataSource == (UXTableDataSource*)0)
            {
            return (i32)0;
            }
        return dataSource.numberOfRows(self);
        }

    UXTableRow* newRow(void)
        {
        return new UXTableRow();
        }
    // The cell class for a column — a subclass (UXOutlineView) overrides column 0 for its disclosure
    // cell.  Called from ensureRows so the pooled cells are the right type from creation.
    UXTableCell* newCell(i32 col)
        {
        return new UXTableCell();
        }

    // Fill row `r`'s cells.  The table lays them out by column and asks the datasource.
    void configureRow(UXTableRow* rv, i32 r)
        {
        i32 ncols = (i32)columns.count();
        i16 cx = (i16)0;
        for (i32 c = (i32)0; c < ncols; c++)
            {
            UXTableColumn* col = (UXTableColumn* ?)columns.get((u16)c);
            UXTableCell* cell = (UXTableCell* ?)rv.subviews.get((u16)c);
            owner.setFrameOf(cell.index, UXGeom.make(cx, (i16)0, col.width, rowHeight));
            cell.text = dataSource.valueForCell(self, r, c); // custom-drawn; NOT copied
            cx = (i16)(cx + col.width);
            }
        }

    // ---- reload: REUSE the row objects, never remove them ---------------------
    //
    // A GEM tree is a flat array whose indices are referenced by every ob_next / ob_head /
    // ob_tail in it, so deleting an object is not a local operation. An outline view
    // re-derives its row list on every expand and collapse, and rebuilding the objects each
    // time would leak a slot per row, for ever.
    //
    // So rows are POOLED: they are created once, reused with new contents, and the surplus
    // is hidden with OF_HIDETREE (which objc_draw and objc_find both honour, so a hidden row
    // is neither drawn nor hit). That is AppKit's cell reuse, arrived at from the other
    // direction — not as an optimisation, but because the tree will not let us do otherwise.
    // Create the column-title header once, spanning the table width at the top.
    void ensureHeader(void)
        {
        if (header != (UXTableHeader*)0)
            {
            return;
            }
        header = new UXTableHeader();
        header.table = self;
        // The header is the scroller's PINNED strip (it does not scroll with the rows).  It lives in the
        // table (not the document), spanning the width above the viewport.
        self.addSubview(header, UXGeom.make((i16)0, (i16)0, self.frame().w, headerH));
        owner.setClipsOf(header.index, true);
        header.setAutoresizeMask((i32)UX_FLEX_WIDTH);
        scroll.setHeaderView(header, headerH);
        }

    // A backend with a NATIVE list (Win32 SysListView32, AppKit NSTableView) fills it from this
    // datasource ONCE, when it realizes the control — the toolkit's row views are a shadow it does
    // not read.  So record that the data moved on, and let realizeTree refill on the next display.
    // GEM draws the rows itself and never looks at this.
    bool nativeNeedsReload(void)
        {
        return nativeReload;
        }
    void clearNativeReload(void)
        {
        nativeReload = false;
        }

    void reloadData(void)
        {
        nativeReload = true;
        nrows = self.countRows();
        self.ensureHeader();
        self.ensureRows(nrows);

        for (i32 r = (i32)0; r < nrows; r++)
            {
            UXTableRow* rv = (UXTableRow* ?)rows.get((u16)r);
            owner.setHiddenOf(rv.index, false); // shown
            owner.setSelectedOf(rv.index, false);
            self.configureRow(rv, r);
            }

        // Whatever is left over from a previous, longer list: hide it. The objects stay.
        for (i32 r = nrows; r < builtRows; r++)
            {
            UXTableRow* rv = (UXTableRow* ?)rows.get((u16)r);
            owner.setHiddenOf(rv.index, true);
            }

        // Tell the scroller how tall the document is (rows are laid out at fixed r*rowHeight in it);
        // it clips + shows/hides its bar, and clamps any now-out-of-range scroll.
        scroll.setLineHeight(rowHeight);
        scroll.setDocumentHeight((i32)nrows * (i32)rowHeight);

        selectedRow = (i32)-1; // the row that was selected may no longer be the same row
        self.setNeedsDisplay();
        }

    // Create row objects (and their cells) up to `want`, reusing everything already built.
    void ensureRows(i32 want)
        {
        i32 ncols = (i32)columns.count();
        UXView* docv = scroll.document();
        for (i32 r = builtRows; r < want; r++)
            {
            UXTableRow* rv = self.newRow();
            rv.table = self;
            rv.row = r;
            // Rows live in the scroller's DOCUMENT at a fixed y; the scroller moves the whole document,
            // so a row never moves relative to its neighbours and never paints over the pinned header.
            docv.addSubview(rv, UXGeom.make((i16)0, (i16)((i32)r * (i32)rowHeight),
                                            docv.frame().w, rowHeight));

            // A row clips its children: a cell whose text overruns its column is cut at the
            // column edge rather than scribbling over the next one — and, more importantly,
            // an off-screen row costs ONE rect test instead of a walk through all its cells.
            owner.setClipsOf(rv.index, true);

            for (i32 c = (i32)0; c < ncols; c++)
                {
                UXTableCell* cell = self.newCell(c);
                rv.addSubview(cell, UXGeom.make((i16)0, (i16)0, (i16)8, rowHeight));
                }
            rows.add(rv);
            }
        if (want > builtRows)
            {
            builtRows = want;
            }
        }

    // Set one row's OS_SELECTED state and repaint ONLY that row.  Selection lives in the object's
    // own state, so it survives a redraw and a future themed row slice would pick it up unchanged.
    bool nativeSelectionNeedsPush(void)
        {
        return nativeSelDirty;
        }
    void clearNativeSelectionPush(void)
        {
        nativeSelDirty = false;
        }
    // Fill `out` with the selected rows, for a driver pushing them into a native list.
    i32 selectedRowList(i32* out, i32 max)
        {
        i32 n = (i32)0;
        for (i32 r = (i32)0; r < nrows && n < max; r = r + (i32)1)
            {
            if (self.isRowSelected(r))
                {
                out[n] = r;
                n = n + (i32)1;
                }
            }
        return n;
        }

    void setRowSelected(i32 r, bool on)
        {
        if (r < (i32)0 || r >= nrows)
            {
            return;
            }
        nativeSelDirty = true;
        UXTableRow* rv = (UXTableRow* ?)rows.get((u16)r);
        owner.setSelectedOf(rv.index, on);
        rv.setNeedsDisplay();
        }
    // Clear every selected row (multi-select may have more than one).
    void deselectAllRows(void)
        {
        for (i32 r = (i32)0; r < nrows; r++)
            {
            if (self.isRowSelected(r))
                {
                self.setRowSelected(r, false);
                }
            }
        }

    // The delegate method is OPTIONAL, so it cannot be called directly — take it as a bound method
    // and test it: `if (f)` is false both when the delegate never implemented it AND when it has been
    // deallocated (the `weak:` receiver zeroes).  `row` is the anchor (the last row touched).
    void fireSelectionChanged(i32 row)
        {
        if (delegate != (UXTableDelegate*)0)
            {
            callback f void(UXTableView * t, i32 row) = &delegate.tableSelectionDidChange;
            if (f)
                {
                f(self, row);
                }
            }
        }

    // Replace the whole selection with row r (a plain click, and the single-select path).
    void selectRow(i32 r)
        {
        // no change
        if (self.selectedCount() == (i32)1 && r >= (i32)0 && self.isRowSelected(r))
            {
            return;
            }
        self.deselectAllRows();
        selectedRow = r;
        self.setRowSelected(r, true);
        self.fireSelectionChanged(r);
        }

    // Toggle row r in/out of the set, keeping the rest (ctrl-click).
    void toggleRow(i32 r)
        {
        if (r < (i32)0 || r >= nrows)
            {
            return;
            }
        bool now = !self.isRowSelected(r);
        self.setRowSelected(r, now);
        selectedRow = now ? r : (i32)-1; // the anchor follows the last row added
        self.fireSelectionChanged(r);
        }

    // Select the contiguous range from the anchor to r, dropping the rest (shift-click).
    void extendSelectionTo(i32 r)
        {
        if (r < (i32)0 || r >= nrows)
            {
            return;
            }
        i32 a = selectedRow >= (i32)0 ? selectedRow : r;
        i32 lo = a < r ? a : r;
        i32 hi = a < r ? r : a;
        self.deselectAllRows();
        for (i32 i = lo; i <= hi; i++)
            {
            self.setRowSelected(i, true);
            }
        self.fireSelectionChanged(r);
        }

    // Which row is under a window-local y (accounting for the header + scroll); clamped to the list so a
    // drag PAST the top/bottom pins to the first/last row rather than selecting nothing.
    i32 rowAtWindowY(i16 wy)
        {
        if (scroll == (UXScrollView*)0 || nrows <= (i32)0)
            {
            return (i32)-1;
            }
        // The document is MOVED by -scrollOffset, so its absolute y already encodes the scroll: a row's
        // content-y is just the pointer minus the document's top.
        i32 contentY = (i32)wy - (i32)scroll.document().absoluteFrame().y;
        i32 row = contentY / (i32)rowHeight;
        if (contentY < (i32)0)
            {
            row = (i32)0;
            }
        if (row < (i32)0)
            {
            row = (i32)0;
            }
        if (row >= nrows)
            {
            row = nrows - (i32)1;
            }
        return row;
        }

    // After a plain press on a row, track the drag: while the button is held, follow the pointer and
    // extend (multi) or move (single) the selection to the row under it.  Modal — the GEM event model
    // has no async motion, so we loop the driver's drag-step until release.  Native tables (win32/mac)
    // return 0 from trackDragStep on the first call, so this is a no-op there (they drag themselves).
    void beginDragSelect(void)
        {
        i32 x = (i32)0;
        i32 y = (i32)0;
        while (gDriver.trackDragStep(&x, &y) != (i32)0)
            {
            i32 row = self.rowAtWindowY((i16)y);
            if (row >= (i32)0)
                {
                // anchor..row contiguous
                if (allowsMultiple)
                    {
                    self.extendSelectionTo(row);
                    }
                // single selection follows
                else
                    {
                    self.selectRow(row);
                    }
                }
            // The run loop is parked in trackDragStep, so repaint here to make the sweep LIVE.
            if (gApp != (UXApplication*)0)
                {
                gApp.displayIfNeeded();
                }
            }
        }

    // Adopt a selection the native backend already made (AppKit's NSTableView owns the click UX):
    // set exactly the rows in list[0..n), anchor on the last, and notify — without echoing back.
    // The native list reporting what the USER did.  Mirror it into the model, then announce it: on
    // this backend the click never reached the toolkit (it arrived as WM_NOTIFY), so without this a
    // recording holds every button press and no sign that a row was ever chosen.  The push flag is
    // cleared, not set — this selection came FROM the control, so it does not need sending back.
    void applyNativeSelection(i32* list, i32 n)
        {
        self.deselectAllRows();
        for (i32 i = (i32)0; i < n; i++)
            {
            self.setRowSelected(list[i], true);
            }
        selectedRow = n > (i32)0 ? list[n - (i32)1] : (i32)-1;
        nativeSelDirty = false; // this selection came FROM the control: nothing to send back
        self.fireSelectionChanged(selectedRow);
        if (gEventTap != (callback void(UXEvent * e))0 && !gInputReplay)
            {
            UXEvent* ev = new UXEvent();
            ev.kind = (u8)UXEventSelected;
            ev.a = (i32)self.index;
            ev.b = selectedRow;
            // The WHOLE set, not just the anchor: a multi-row selection replayed as one row otherwise.
            UXIndexSet* sel = new UXIndexSet();
            for (i32 r = (i32)0; r < nrows; r = r + (i32)1)
                {
                if (self.isRowSelected(r))
                    {
                    sel.addIndex(r);
                    }
                }
            ev.data = (Object*)sel;
            gEventTap(ev);
            }
        }
    }
