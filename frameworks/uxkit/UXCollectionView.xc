// UXCollectionView.xc — a grid of items (NSCollectionView in shape); the desktop icon view.
//
// Items of a fixed size flow left-to-right and wrap to new rows to fill the width — the layout the
// Finder desktop and any icon grid wants.  The grid arithmetic (how many columns fit, each item's
// rectangle, the total content height for scrolling) and hit-testing are pure geometry, so they are
// unit-tested without a window.  Multi-selection reuses UXIndexSet.  Drawing rides the UXControl seam.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"
#import "UXIndexSet.xc"
#import "Array.xc"

class UXCollectionItem : Object
    {
    Object* obj;
    u8* label;
    i16 x;
    i16 y;
    i16 w;
    i16 h; // laid-out frame
    void init(void)
        {
        obj = (Object*)0;
        label = (u8*)"";
        x = (i16)0;
        y = (i16)0;
        w = (i16)0;
        h = (i16)0;
        }
    }

    class UXCollectionView : UXControl
    {
    Array<UXCollectionItem>* items;
    UXIndexSet* selected;
    i16 itemW;
    i16 itemH;
    i16 hGap;
    i16 vGap;
    i16 inset;
    i32 layoutCols; // columns from the last layout (for hit-testing)
    i32 contentHeight;

    void init(void)
        {
        super.init();
        items = new Array();
        selected = new UXIndexSet();
        itemW = (i16)64;
        itemH = (i16)64;
        hGap = (i16)16;
        vGap = (i16)16;
        inset = (i16)12;
        layoutCols = (i32)1;
        contentHeight = (i32)0;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }

    // ---- model ---------------------------------------------------------------
    void addItem(Object* obj, u8* label)
        {
        UXCollectionItem* it = new UXCollectionItem();
        it.obj = obj;
        it.label = label;
        items.add(it);
        }
    void clear(void)
        {
        items.removeAll();
        selected.removeAllIndexes();
        }
    i32 count(void)
        {
        return (i32)items.count();
        }
    UXCollectionItem* itemAt(i32 i)
        { return (UXCollectionItem* ?)items.get((u16)i);
        }
    void setItemSize(i16 w, i16 h)
        {
        itemW = w;
        itemH = h;
        }
    void setSpacing(i16 h, i16 v)
        {
        hGap = h;
        vGap = v;
        }
    void setInset(i16 v)
        {
        inset = v;
        }

    // ---- layout --------------------------------------------------------------
    i32 columnsFor(i16 width)
        {
        i32 usable = (i32)width - (i32)inset * (i32)2;
        i32 step = (i32)itemW + (i32)hGap;
        i32 cols = step > (i32)0 ? (usable + (i32)hGap) / step : (i32)1; // n*itemW + (n-1)*hGap <= usable
        return cols < (i32)1 ? (i32)1 : cols;
        }
    void layout(i16 width)
        {
        i32 n = self.count();
        layoutCols = self.columnsFor(width);
        if (n == (i32)0)
            {
            contentHeight = (i32)0;
            return;
            }
        i32 stepX = (i32)itemW + (i32)hGap;
        i32 stepY = (i32)itemH + (i32)vGap;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            i32 r = i / layoutCols;
            i32 c = i % layoutCols;
            UXCollectionItem* it = self.itemAt(i);
            it.x = (i16)((i32)inset + c * stepX);
            it.y = (i16)((i32)inset + r * stepY);
            it.w = itemW;
            it.h = itemH;
            }
        i32 rows = (n + layoutCols - (i32)1) / layoutCols;
        contentHeight = (i32)inset * (i32)2 + rows * stepY - (i32)vGap;
        }
    i32 contentHeightFor(i16 width)
        {
        self.layout(width);
        return contentHeight;
        }

    // index of the item whose laid-out box contains (x,y), else -1 (gaps included).
    i32 itemAtPoint(i16 px, i16 py)
        {
        if (px < inset || py < inset)
            {
            return (i32)-1;
            }
        i32 stepX = (i32)itemW + (i32)hGap;
        i32 stepY = (i32)itemH + (i32)vGap;
        i32 c = ((i32)px - (i32)inset) / stepX;
        i32 r = ((i32)py - (i32)inset) / stepY;
        if (c >= layoutCols)
            {
            return (i32)-1;
            }
        i32 idx = r * layoutCols + c;
        if (idx < (i32)0 || idx >= self.count())
            {
            return (i32)-1;
            }
        UXCollectionItem* it = self.itemAt(idx);
        if (px >= it.x && px < (i16)(it.x + it.w) && py >= it.y && py < (i16)(it.y + it.h))
            {
            return idx;
            }
        return (i32)-1; // fell in the gap between items
        }

    // ---- selection (via UXIndexSet) -----------------------------------------
    void selectItem(i32 i)
        {
        selected.removeAllIndexes();
        selected.addIndex(i);
        }
    void addToSelection(i32 i)
        {
        selected.addIndex(i);
        }
    void toggleSelection(i32 i)
        {
        if (selected.containsIndex(i))
            {
            selected.removeIndex(i);
            }
        else
            {
            selected.addIndex(i);
            }
        }
    void deselectAll(void)
        {
        selected.removeAllIndexes();
        }
    bool isSelected(i32 i)
        {
        return selected.containsIndex(i);
        }
    i32 selectionCount(void)
        {
        return selected.count();
        }
    i32 firstSelected(void)
        {
        return selected.firstIndex();
        }

    // ---- interaction ---------------------------------------------------------
    void mouseDown(UXEvent* e)
        {
        if (!self.isEnabled())
            {
            return;
            }
        UXRect abs = self.absoluteFrame();
        i16 lx = (i16)((i32)e.x - abs.x);
        i16 ly = (i16)((i32)e.y - abs.y);
        i32 idx = self.itemAtPoint(lx, ly);
        if (idx >= (i32)0)
            {
            if ((e.modifiers & (u16)UX_MOD_SHIFT) != (u16)0)
                {
                self.toggleSelection(idx);
                }
            else
                {
                self.selectItem(idx);
                }
            self.setNeedsDisplay();
            self.fire();
            }
        else
            {
            self.deselectAll();
            self.setNeedsDisplay();
            }
        }

    // ---- drawing -------------------------------------------------------------
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        self.layout(b.w);
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            UXCollectionItem* it = self.itemAt(i);
            if (self.isSelected(i))
                {
                g.fillRect(UXGeom.make(it.x, it.y, it.w, it.h), (i32)250); // UX_PEN_SELECT
                }
            // Icon stand-in: a WHITE tile with a grey border, so it reads as an icon card on ANY backdrop.
            // (A flat pen-8 grey square vanished on the Win32 dialog-face window, which is the same grey.)
            i16 tx = (i16)(it.x + (i16)8);
            i16 ty = it.y;
            i16 tw = (i16)(it.w - (i16)16);
            i16 th = (i16)(it.h - (i16)16);
            g.fillRect(UXGeom.make(tx, ty, tw, th), (i32)0);                          // white tile
            g.fillRect(UXGeom.make(tx, ty, tw, (i16)1), (i32)9);                      // top edge
            g.fillRect(UXGeom.make(tx, (i16)(ty + th - (i16)1), tw, (i16)1), (i32)9); // bottom edge
            g.fillRect(UXGeom.make(tx, ty, (i16)1, th), (i32)9);                      // left edge
            g.fillRect(UXGeom.make((i16)(tx + tw - (i16)1), ty, (i16)1, th), (i32)9); // right edge
            g.drawText(it.label, it.x, (i16)(it.y + it.h - (i16)12), (i32)1, (i32)0);
            }
        }
    }
