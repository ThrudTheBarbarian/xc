// UXOutlineView.xc — a table whose rows have a hierarchy.
//
// It is an UXTableView, so everything the table already earned comes along unchanged:
// rows and cells are real GEM objects, GEM draws the cell text, objc_find hit-tests,
// the responder chain routes a cell click to its row, the AES runs the scrollbar, and
// OF_CLIPCHILDREN prunes the rows you cannot see.
//
// What an outline ADDS is exactly three things:
//
//   1. a datasource that speaks in ITEMS AND CHILDREN rather than rows and columns
//   2. a FLATTENING pass — the expanded tree becomes the list of visible rows
//   3. an indent, and a disclosure triangle that toggles a row open or shut
//
// The flattening is the whole idea. An outline view is not a tree widget; it is a table
// whose row list is DERIVED from a tree. Expanding a node re-derives the list. So there
// is no second drawing path, no second hit-test, and no second scrolling model — an
// outline row is a table row, and everything downstream of that already works.
//
// LIFETIME: as with UXTableView, valueForItem's string goes straight into ob_spec and is
// NOT copied. It must outlive the row.

#import "UXGem.xc"
#import "UXTableView.xc"

// The datasource speaks in ITEMS. `item` is nil for the root, so one method serves both
// "what are the top-level rows?" and "what are this node's children?".
protocol UXOutlineDataSource
    {
    i32 numberOfChildren(UXOutlineView * o, Object * item);
    Object* childOfItem(UXOutlineView * o, Object * item, i32 i);
    bool isExpandable(UXOutlineView * o, Object * item);
    u8* valueForItem(UXOutlineView * o, Object * item, i32 col);
    }

#define UX_INDENT 12 // px per level
#define UX_TRI 8     // the disclosure triangle's box

// One visible line: the item, how deep it sits, and whether it is open.
class UXOutlineNode : Object
    {
    Object* item;
    i32 level;
    bool expandable;
    bool expanded;
    void init(void)
        {
        item = (Object*)0;
        level = (i32)0;
        expandable = false;
        expanded = false;
        }
    // Factory: keeps the `new` out of flatten()'s loop (the compiler warns on new-in-a-loop even though
    // the node is kept by the `nodes` array).
    static UXOutlineNode* make(Object* it, i32 lv, bool exp, bool open)
        {
        UXOutlineNode* n = new UXOutlineNode();
        n.item = it;
        n.level = lv;
        n.expandable = exp;
        n.expanded = open;
        return n;
        }
    }

    // A row that draws a disclosure triangle, and toggles when you hit it.
    class UXOutlineRow : UXTableRow
    {
    weak : UXOutlineView* outline;
    void init(void)
        {
        super.init();
        outline = (UXOutlineView*)0;
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        super.drawRect(g, dirty); // the selected-row background
        if (outline == (UXOutlineView*)0)
            {
            return;
            }

        UXOutlineNode* n = outline.nodeAt(row);
        if (n == (UXOutlineNode*)0)
            {
            return;
            }
        if (!n.expandable)
            {
            return;
            }

        // The triangle sits in the indent gutter this row's level bought it.
        i16 h = self.bounds().h;
        i16 x = (i16)((i32)n.level * (i32)UX_INDENT + (i32)2);
        i16 y = (i16)((i32)h / (i32)2 - (i32)UX_TRI / (i32)2);

        // ▼
        if (n.expanded)
            {
            g.fillTriangle(x, y,
                           (i16)(x + UX_TRI), y,
                           (i16)(x + UX_TRI / 2), (i16)(y + UX_TRI), (i32)1);
            }
        // ▶
        else
            {
            g.fillTriangle(x, y,
                           (i16)(x + UX_TRI), (i16)(y + UX_TRI / 2),
                           x, (i16)(y + UX_TRI), (i32)1);
            }
        }

    // A click in the triangle's gutter toggles; anywhere else selects, as a table row does.
    //
    // The click arrives here even when it landed on a CELL, because a cell does not handle
    // mouseDown — so `e.x` may be inside a child, and the test has to be against the row's
    // own absolute frame rather than against whatever got hit.
    void mouseDown(UXEvent* e)
        {
        if (outline != (UXOutlineView*)0)
            {
            UXOutlineNode* n = outline.nodeAt(row);
            if (n != (UXOutlineNode*)0 && n.expandable)
                {
                UXRect f = self.absoluteFrame();
                i16 gx = (i16)(f.x + (i16)((i32)n.level * (i32)UX_INDENT));
                if (e.x >= gx && e.x < (i16)(gx + (i16)(UX_TRI + (i16)4)))
                    {
                    outline.toggleRow(row);
                    return; // the toggle CONSUMES the click
                    }
                }
            }
        super.mouseDown(e); // otherwise: select, exactly as a table row
        }
    }

    class UXOutlineView : UXTableView
    {
    weak : UXOutlineDataSource* outlineSource;
    Array<UXOutlineNode>* nodes; // UXOutlineNode, one per VISIBLE line
    Array* expandedItems;        // items the user has opened — survives a re-flatten

    void init(void)
        {
        super.init();
        outlineSource = (UXOutlineDataSource*)0;
        nodes = new Array();
        expandedItems = new Array();
        }

    void setOutlineSource(UXOutlineDataSource* d)
        {
        outlineSource = d;
        }

    // Native tables (win32 SysListView32 / AppKit NSTableView) pull rows from these, not the subtree.
    // Feed them the flattened item list, so a native backend shows the visible tree as a flat list
    // (no triangles/indent — a proper native tree control, SysTreeView32 / NSOutlineView, is the next
    // step).  nativeRowCount -> countRows() re-flattens; the driver reads text right after.
    u8* nativeCellText(i32 row, i32 col)
        {
        UXOutlineNode* n = self.nodeAt(row);
        if (n == (UXOutlineNode*)0 || outlineSource == (UXOutlineDataSource*)0)
            {
            return (u8*)"";
            }
        return outlineSource.valueForItem(self, n.item, col);
        }

    // ---- native TREE bridge (win32 SysTreeView32 / AppKit NSOutlineView) ------
    // The native control is item-based, exactly like the datasource — so it asks these, passing an
    // opaque item pointer (the app's node, boxed by the shim) back down.  item == 0 is the root.
    i32 nativeIsOutline(void)
        {
        return (i32)1;
        }
    i32 nativeChildren(pointer item)
        {
        return outlineSource == (UXOutlineDataSource*)0 ? (i32)0
                                                        : outlineSource.numberOfChildren(self, (Object*)item);
        }
    pointer nativeChild(pointer item, i32 i)
        {
        return outlineSource == (UXOutlineDataSource*)0 ? (pointer)0
                                                        : (pointer)outlineSource.childOfItem(self, (Object*)item, i);
        }
    i32 nativeExpandable(pointer item)
        {
        return (outlineSource != (UXOutlineDataSource*)0 && outlineSource.isExpandable(self, (Object*)item))
                   ? (i32)1
                   : (i32)0;
        }
    u8* nativeItemValue(pointer item, i32 col)
        {
        return outlineSource == (UXOutlineDataSource*)0 ? (u8*)""
                                                        : outlineSource.valueForItem(self, (Object*)item, col);
        }
    // The native control expanded/collapsed an item: record it AND re-flatten, so the neutral row
    // list matches the native visible order (native selection is reported by row, mapped through it).
    void nativeDidExpand(pointer item, i32 on)
        {
        self.setExpanded((Object*)item, on != (i32)0);
        nodes.removeAll();
        if (outlineSource != (UXOutlineDataSource*)0)
            {
            self.flatten((Object*)0, (i32)0);
            }
        }
    i32 nativeIsItemExpanded(pointer item)
        {
        return self.isExpanded((Object*)item) ? (i32)1 : (i32)0;
        }
    // Win32's TreeView reports selection by item (its lParam); map it back to the flattened row so the
    // same applyNativeSelection the list uses fires the delegate unchanged.  -1 if not visible.
    i32 rowForItem(pointer item)
        {
        for (u16 i = (u16)0; i < nodes.count(); i = i + (u16)1)
            {
            if ((pointer)((UXOutlineNode* ?)nodes.get(i)).item == item)
                {
                return (i32)i;
                }
            }
        return (i32)-1;
        }

    UXOutlineNode* nodeAt(i32 r)
        {
        if (r < (i32)0 || r >= (i32)nodes.count())
            {
            return (UXOutlineNode*)0;
            }
        return (UXOutlineNode* ?)nodes.get((u16)r);
        }

    i32 visibleCount(void)
        {
        return (i32)nodes.count();
        }

    // Expansion is remembered against the ITEM, not against a row index — a row index is
    // meaningless the moment anything above it opens or shuts.
    bool isExpanded(Object* item)
        {
        for (u16 i = (u16)0; i < expandedItems.count(); i++)
            {
            if (expandedItems.get(i) == item)
                {
                return true;
                }
            }
        return false;
        }

    void setExpanded(Object* item, bool open)
        {
        for (u16 i = (u16)0; i < expandedItems.count(); i++)
            {
            if (expandedItems.get(i) == item)
                {
                if (!open)
                    {
                    expandedItems.removeAt(i);
                    }
                return; // already in the right state
                }
            }
        if (open)
            {
            expandedItems.add(item);
            }
        }

    // THE FLATTENING.  Walk the item tree, and emit a line for every item whose ancestors
    // are all open.  This is the only place the hierarchy exists; everything downstream
    // sees a flat list of rows, which is precisely why it all still works.
    void flatten(Object* item, i32 level)
        {
        i32 n = outlineSource.numberOfChildren(self, item);
        for (i32 i = (i32)0; i < n; i++)
            {
            Object* child = outlineSource.childOfItem(self, item, i);

            bool exp = outlineSource.isExpandable(self, child);
            UXOutlineNode* node = UXOutlineNode.make(child, level, exp, exp && self.isExpanded(child));
            nodes.add(node);

            // depth-first
            if (node.expanded)
                {
                self.flatten(child, level + (i32)1);
                }
            }
        }

    // ---- the three hooks.  Everything else is UXTableView's, unchanged. --------

    // Re-derive the visible line list from the item tree.  This is where the hierarchy
    // lives, and it is the ONLY place it lives.
    i32 countRows(void)
        {
        if (outlineSource == (UXOutlineDataSource*)0)
            {
            return (i32)0;
            }

        // removeAll(), not `nodes = new Array()`: reloading a table should not churn the heap.
        nodes.removeAll();
        self.flatten((Object*)0, (i32)0); // nil item = the root
        return (i32)nodes.count();
        }

    UXTableRow* newRow(void)
        {
        UXOutlineRow* r = new UXOutlineRow();
        r.outline = self;
        return r;
        }

    // Like the table's, but the first column is pushed right by this row's depth, leaving
    // the gutter the disclosure triangle draws into.
    void configureRow(UXTableRow* rv, i32 r)
        {
        UXOutlineNode* node = self.nodeAt(r);
        if (node == (UXOutlineNode*)0)
            {
            return;
            }

        i32 ncols = (i32)columns.count();
        i16 cx = (i16)0;
        for (i32 c = (i32)0; c < ncols; c++)
            {
            UXTableColumn* col = (UXTableColumn* ?)columns.get((u16)c);
            i16 ind = (i32)c == (i32)0
                          ? (i16)((i32)node.level * (i32)UX_INDENT + (i32)UX_TRI + (i32)4)
                          : (i16)0;

            UXTableCell* cell = (UXTableCell* ?)rv.subviews.get((u16)c);
            owner.setFrameOf(cell.index, UXGeom.make((i16)(cx + ind), (i16)0,
                                                     (i16)(col.width - ind), rowHeight));
            cell.text = outlineSource.valueForItem(self, node.item, c); // custom-drawn cell (not spec)
            cx = (i16)(cx + col.width);
            }
        }

    void toggleRow(i32 r)
        {
        UXOutlineNode* n = self.nodeAt(r);
        if (n == (UXOutlineNode*)0 || !n.expandable)
            {
            return;
            }
        self.setExpanded(n.item, !n.expanded);
        self.reloadData(); // re-derive: the visible rows have changed
        }
    }
