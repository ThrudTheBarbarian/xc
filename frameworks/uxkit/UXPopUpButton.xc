// UXPopUpButton.xc — a drop-down selection button (NSPopUpButton in shape).
//
// Shows one selected item from a list; clicking pops a menu of the items (the backend runs the actual
// popup) and choosing one selects it.  The item list + selection (by index, tag or title) is the pure,
// testable model; drawing the closed button + running the menu ride the backend.  The space-efficient
// single-choice control for a form or toolbar.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

class UXPopUpItem : Object
    {
    u8* title;
    i32 tag;
    void init(void)
        {
        title = (u8*)"";
        tag = (i32)0;
        }
    }

    class UXPopUpButton : UXControl
    {
    Array<UXPopUpItem>* items;
    i32 selected;
    void init(void)
        {
        super.init();
        items = new Array();
        selected = (i32)-1;
        }
    // native NSPopUpButton; drawRect is the GEM fallback
    UXKind kind(void)
        {
        return UXKindPopup;
        }

    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        t.setPeerOf(index, (pointer)self);
        }

    // ---- native-control bridge -----------------------------------------------
    i32 nativeItemCount(void)
        {
        return self.count();
        }
    u8* nativeItemTitle(i32 i)
        {
        return self.titleAt(i);
        }
    i32 nativeSelected(void)
        {
        return selected;
        }
    void applyNativeSelection(i32 i)
        {
        self.selectItem(i);
        }

    void addItem(u8* title, i32 tag)
        {
        UXPopUpItem* it = new UXPopUpItem();
        it.title = title;
        it.tag = tag;
        items.add(it);
        // first item selected by default
        if (selected < (i32)0)
            {
            selected = (i32)0;
            }
        }
    void removeAllItems(void)
        {
        items.removeAll();
        selected = (i32)-1;
        }
    i32 count(void)
        {
        return (i32)items.count();
        }
    UXPopUpItem* itemAt(i32 i)
        { return (UXPopUpItem* ?)items.get((u16)i);
        }
    u8* titleAt(i32 i)
        {
        return self.itemAt(i).title;
        }
    i32 tagAt(i32 i)
        {
        return self.itemAt(i).tag;
        }

    void selectItem(i32 i)
        {
        if (i >= (i32)0 && i < self.count())
            {
            selected = i;
            }
        }
    void selectByTag(i32 tag)
        {
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            if (self.itemAt(i).tag == tag)
                {
                selected = i;
                return;
                }
            }
        }
    void selectByTitle(u8* title)
        {
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            if (UXPopUpButton.streq(self.itemAt(i).title, title))
                {
                selected = i;
                return;
                }
            }
        }
    static bool streq(u8* a, u8* b)
        {
        if (a == (u8*)0 || b == (u8*)0)
            {
            return a == b;
            }
        i32 i = (i32)0;
        while (a[i] != (u8)0 && b[i] != (u8)0)
            {
            if (a[i] != b[i])
                {
                return false;
                }
            i = i + (i32)1;
            }
        return a[i] == b[i];
        }

    i32 selectedIndex(void)
        {
        return selected;
        }
    u8* selectedTitle(void)
        {
        return selected >= (i32)0 && selected < self.count() ? self.titleAt(selected) : (u8*)"";
        }
    i32 selectedTag(void)
        {
        return selected >= (i32)0 && selected < self.count() ? self.tagAt(selected) : (i32)-1;
        }

    void mouseDown(UXEvent* e)
        {
        if (!self.isEnabled())
            {
            return;
            }
        // Where the popup is a NATIVE control (AppKit's NSPopUpButton, Win32's COMBOBOX) the OS drops
        // the list itself and reports back through applyNativeSelection; its driver returns -1 here and
        // this is just the re-affirming click.  Where it is not (GEM draws the bezel itself), the driver
        // runs a menu at the button's bottom-left and hands back the chosen index.
        if (gDriver != (UXViewDriver*)0)
            {
            UXRect a = self.absoluteFrame();
            i32 pick = gDriver.runPopupMenu((pointer)self, (i32)a.x, (i32)(a.y + a.h));
            if (pick >= (i32)0 && pick < self.count())
                {
                self.selectItem(pick);
                }
            }
        self.setNeedsDisplay();
        self.fire();
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        // The themed popup bezel (its right end carries the disclosure chevron); Aristo2 on GEM, native
        // NSPopUpButton/combobox elsewhere skip this.  Just lay the current title over it.
        g.drawTheme((u8*)"popup", UXGeom.make((i16)0, (i16)0, b.w, b.h));
        g.drawText(self.selectedTitle(), (i16)8, (i16)((b.h - (i16)12) / (i16)2), (i32)1, (i32)0);
        }
    }
