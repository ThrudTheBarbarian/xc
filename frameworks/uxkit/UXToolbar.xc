// UXToolbar.xc — a toolbar of items (NSToolbar in shape): icons + text, flexible spaces, overflow.
//
// Items lay out left-to-right.  FLEXIBLE-SPACE items absorb the leftover width (so a button group can
// be pushed to the right, or centred between two flexible spaces).  When the fixed items exceed the
// width, the trailing ones spill into an OVERFLOW set (a real toolbar shows them under a chevron).
// The layout and hit-testing are pure geometry — unit-tested without a window; drawing rides the
// UXControl seam.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"
#import "Array.xc"

#define UXTB_ITEM 0
#define UXTB_SPACE 1 // a fixed gap
#define UXTB_FLEX 2  // a flexible gap that absorbs leftover width
#define UXTB_SEP 3   // a separator line

class UXToolbarItem : Object
    {
    i32 type;
    u8* ident;
    u8* label;
    i32 tag;
    i16 natWidth; // natural (fixed) width
    i16 x;
    i16 w;        // laid-out
    bool visible; // false when it overflows
    void init(void)
        {
        type = (i32)UXTB_ITEM;
        ident = (u8*)"";
        label = (u8*)"";
        tag = (i32)0;
        natWidth = (i16)48;
        x = (i16)0;
        w = (i16)0;
        visible = true;
        }
    }

    class UXToolbar : UXControl
    {
    Array<UXToolbarItem>* items;
    i16 inset;
    i16 spacing;
    i16 fixedSpaceWidth;
    i32 selectedIndex;
    i32 overflowCount; // how many items overflowed at the last layout

    void init(void)
        {
        super.init();
        items = new Array();
        inset = (i16)8;
        spacing = (i16)6;
        fixedSpaceWidth = (i16)16;
        selectedIndex = (i32)-1;
        overflowCount = (i32)0;
        }
    // native NSToolbar (window chrome); drawRect is the GEM/Win32 fallback
    UXKind kind(void)
        {
        return UXKindToolbar;
        }
    static i32 tbSlen(u8* s)
        {
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }

    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        t.setPeerOf(index, (pointer)self);
        }

    // ---- native-control bridge (the driver builds an NSToolbar from these) ---------------------
    i32 nativeItemCount(void)
        {
        return self.count();
        }
    // UXTB_ITEM / SPACE / FLEX / SEP
    i32 nativeItemType(i32 i)
        {
        return self.itemAt(i).type;
        }
    u8* nativeItemLabel(i32 i)
        {
        return self.itemAt(i).label;
        }
    // Win32 maps this to a standard toolbar icon
    u8* nativeItemIdent(i32 i)
        {
        return self.itemAt(i).ident;
        }
    i32 nativeItemTag(i32 i)
        {
        return self.itemAt(i).tag;
        }
    // A native toolbar item with this tag was clicked: record it as the selection (the driver fires).
    void applyNativeItemClick(i32 tag)
        {
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            if (self.itemAt(i).tag == tag)
                {
                selectedIndex = i;
                return;
                }
            }
        }

    // ---- model ---------------------------------------------------------------
    void addItem(u8* ident, u8* label, i32 tag, i16 width)
        {
        UXToolbarItem* it = new UXToolbarItem();
        it.type = (i32)UXTB_ITEM;
        it.ident = ident;
        it.label = label;
        it.tag = tag;
        it.natWidth = width;
        items.add(it);
        }
    void addFlexibleSpace(void)
        {
        UXToolbarItem* it = new UXToolbarItem();
        it.type = (i32)UXTB_FLEX;
        it.natWidth = (i16)0;
        items.add(it);
        }
    void addSpace(void)
        {
        UXToolbarItem* it = new UXToolbarItem();
        it.type = (i32)UXTB_SPACE;
        it.natWidth = fixedSpaceWidth;
        items.add(it);
        }
    void addSeparator(void)
        {
        UXToolbarItem* it = new UXToolbarItem();
        it.type = (i32)UXTB_SEP;
        it.natWidth = (i16)2;
        items.add(it);
        }
    void clear(void)
        {
        items.removeAll();
        selectedIndex = (i32)-1;
        }
    i32 count(void)
        {
        return (i32)items.count();
        }
    UXToolbarItem* itemAt(i32 i)
        { return (UXToolbarItem* ?)items.get((u16)i);
        }
    i32 selection(void)
        {
        return selectedIndex;
        }
    i32 overflow(void)
        {
        return overflowCount;
        }

    // ---- layout --------------------------------------------------------------
    void layout(i16 width)
        {
        i32 n = self.count();
        overflowCount = (i32)0;
        if (n == (i32)0)
            {
            return;
            }

        // pass 1: total fixed width (everything except flexible spaces) + flexible count + gaps
        i32 fixedTotal = (i32)0;
        i32 flexCount = (i32)0;
        i32 gaps = (i32)0;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            UXToolbarItem* it = self.itemAt(i);
            if (it.type == (i32)UXTB_FLEX)
                {
                flexCount = flexCount + (i32)1;
                }
            else
                {
                fixedTotal = fixedTotal + (i32)it.natWidth;
                }
            if (i < n - (i32)1)
                {
                gaps = gaps + (i32)spacing;
                }
            }
        i32 avail = (i32)width - (i32)inset * (i32)2;
        i32 flexTotal = avail - fixedTotal - gaps;
        if (flexTotal < (i32)0)
            {
            flexTotal = (i32)0;
            }
        i32 flexEach = flexCount > (i32)0 ? flexTotal / flexCount : (i32)0;

        // pass 2: place, marking anything that runs past the right edge as overflow
        i16 x = inset;
        i32 limit = (i32)width - (i32)inset;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            UXToolbarItem* it = self.itemAt(i);
            i16 w = it.type == (i32)UXTB_FLEX ? (i16)flexEach : it.natWidth;
            // no flex to absorb: it overflows
            if (flexCount == (i32)0 && (i32)x + (i32)w > limit)
                {
                it.visible = false;
                overflowCount = overflowCount + (i32)1;
                continue;
                }
            it.visible = true;
            it.x = x;
            it.w = w;
            x = (i16)(x + w + spacing);
            }
        }

    // index of the visible, clickable item (not a space/separator) at local x, else -1.
    i32 itemAtLocalX(i16 lx)
        {
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            UXToolbarItem* it = self.itemAt(i);
            if (it.visible && it.type == (i32)UXTB_ITEM && lx >= it.x && lx < (i16)(it.x + it.w))
                {
                return i;
                }
            }
        return (i32)-1;
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
        i32 idx = self.itemAtLocalX(lx);
        if (idx >= (i32)0)
            {
            selectedIndex = idx;
            self.setNeedsDisplay();
            self.fire();
            }
        }

    // ---- drawing -------------------------------------------------------------
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        self.layout(b.w);
        g.fillRect(UXGeom.make((i16)0, (i16)0, b.w, b.h), (i32)8); // toolbar face
        i16 midY = (i16)((b.h - (i16)12) / (i16)2);
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            UXToolbarItem* it = self.itemAt(i);
            if (!it.visible)
                {
                continue;
                }
            if (it.type == (i32)UXTB_SEP)
                {
                g.fillRect(UXGeom.make((i16)(it.x), (i16)4, (i16)1, (i16)(b.h - (i16)8)), (i32)9);
                }
            else if (it.type == (i32)UXTB_ITEM)
                {
                // a raised face per item, so the fallback reads as buttons
                g.fillRect(UXGeom.make(it.x, (i16)2, it.w, (i16)(b.h - (i16)4)),
                           i == selectedIndex ? (i32)250 : (i32)0);
                g.fillRect(UXGeom.make(it.x, (i16)2, it.w, (i16)1), (i32)9);
                g.fillRect(UXGeom.make(it.x, (i16)(b.h - (i16)3), it.w, (i16)1), (i32)9);
                g.fillRect(UXGeom.make(it.x, (i16)2, (i16)1, (i16)(b.h - (i16)4)), (i32)9);
                g.fillRect(UXGeom.make((i16)(it.x + it.w - (i16)1), (i16)2, (i16)1, (i16)(b.h - (i16)4)), (i32)9);
                if ((i32)b.h >= (i32)40)
                    {
                    // a TALL toolbar is the icon-above-text idiom: the glyph
                    // box up top (real icon art rides the ident later), the
                    // label centred beneath
                    i16 gx = (i16)(it.x + (i16)(((i32)it.w - (i32)16) / (i32)2));
                    g.fillRect(UXGeom.make(gx, (i16)6, (i16)16, (i16)16), (i32)8);
                    g.fillRect(UXGeom.make(gx, (i16)6, (i16)16, (i16)1), (i32)9);
                    g.fillRect(UXGeom.make(gx, (i16)21, (i16)16, (i16)1), (i32)9);
                    g.fillRect(UXGeom.make(gx, (i16)6, (i16)1, (i16)16), (i32)9);
                    g.fillRect(UXGeom.make((i16)(gx + (i16)15), (i16)6, (i16)1, (i16)16), (i32)9);
                    i32 lw = UXToolbar.tbSlen(it.label) * (i32)6;
                    i16 lx = (i16)(it.x + (i16)(((i32)it.w - lw) / (i32)2));
                    if (lx < (i16)(it.x + (i16)2))
                        {
                        lx = (i16)(it.x + (i16)2);
                        }
                    g.drawText(it.label, lx, (i16)(b.h - (i16)16), (i32)1, (i32)0);
                    }
                else
                    {
                    g.drawText(it.label, (i16)(it.x + (i16)6), midY, (i32)1, (i32)0);
                    }
                }
            }
        }
    }
