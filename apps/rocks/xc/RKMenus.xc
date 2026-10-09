// RKMenus.xc — making menus.
//
// A menu is an ordinary resource tree (UXR_K_MENU), the classic GEM shape: a root box holding a bar
// (a box of G_TITLEs, one per menu) and an "active" area (a box of drop-down boxes, one per menu),
// each drop-down holding its G_STRING items.  A title and its drop-down are the same index under the
// bar and the active box.  Rocks reads and writes that shape, so a menu made here is a menu any GEM
// reads, and the outline shows it like any other tree.
//
// More than one menu may live in a document; the one the application installs is the document's MAIN
// menu (see the app-delegate link), and swapping it is a matter of changing that link.
#import "UXRscModel.xc"

#define RKMENU_BAR_H 20   // the bar's height
#define RKMENU_DD_W 132   // a drop-down's width (and its items')
#define RKMENU_ITEM_H 16  // one item's height
#define RKMENU_GAP 8      // space between drop-downs, so the editor can read them

class RKMenu : Object
    {
    // A new, empty menu tree in `doc`: a root box with a bar and an active area, and one title.
    static UXRscTree* newMenu(UXRscDoc* doc, u8* name)
        {
        UXRscTree* t = new UXRscTree();
        t.kind = (i32)UXR_K_MENU;
        t.name = name;
        UXRscObject* root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)320, (i32)180);
        UXRscObject* bar = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)320, (i32)RKMENU_BAR_H);
        root.addChild(bar);
        UXRscObject* active = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)RKMENU_BAR_H, (i32)320, (i32)160);
        root.addChild(active);
        t.root = root;
        doc.addTree(t);
        return t;
        }
    // One title (a menu entry on the bar) and, under the active area, its drop-down.  They keep the
    // same index, which is the whole linkage.  Returns the title object.
    static UXRscObject* addTitle(UXRscTree* t, u8* title)
        {
        if (t == (UXRscTree*)0 || t.root == (UXRscObject*)0 || t.root.childCount() < (i32)2)
            {
            return (UXRscObject*)0;
            }
        UXRscObject* bar = t.root.childAt((i32)0);
        UXRscObject* active = t.root.childAt((i32)1);
        i32 bx = (i32)0;
        if (bar.childCount() > (i32)0)
            {
            UXRscObject* last = bar.childAt(bar.childCount() - (i32)1);
            bx = last.x + last.w;
            }
        UXRscObject* ti = UXRscObject.make((i32)UXR_T_TITLE, bx, (i32)0, (i32)44, (i32)RKMENU_BAR_H);
        ti.text = title;
        bar.addChild(ti);
        i32 dx = (i32)0;
        if (active.childCount() > (i32)0)
            {
            UXRscObject* lastd = active.childAt(active.childCount() - (i32)1);
            dx = lastd.x + lastd.w + (i32)RKMENU_GAP;
            }
        UXRscObject* dd = UXRscObject.make((i32)UXR_T_BOX, dx, (i32)0, (i32)RKMENU_DD_W, (i32)RKMENU_ITEM_H);
        dd.flags = (i32)UXR_F_HIDETREE; // GEM keeps a drop-down hidden until its title is opened
        active.addChild(dd);
        return ti;
        }
    // The drop-down box for title `i` (0-based), or 0.
    static UXRscObject* dropdownAt(UXRscTree* t, i32 i)
        {
        if (t == (UXRscTree*)0 || t.root == (UXRscObject*)0 || t.root.childCount() < (i32)2)
            {
            return (UXRscObject*)0;
            }
        UXRscObject* active = t.root.childAt((i32)1);
        if (i < (i32)0 || i >= active.childCount())
            {
            return (UXRscObject*)0;
            }
        return active.childAt(i);
        }
    // Append a string item to the drop-down for title `i`.  `text` of "-" is GEM's separator.
    static UXRscObject* addItem(UXRscTree* t, i32 i, u8* text)
        {
        UXRscObject* dd = RKMenu.dropdownAt(t, i);
        if (dd == (UXRscObject*)0)
            {
            return (UXRscObject*)0;
            }
        i32 y = dd.childCount() * (i32)RKMENU_ITEM_H;
        UXRscObject* s = UXRscObject.make((i32)UXR_T_STRING, (i32)0, y, (i32)RKMENU_DD_W, (i32)RKMENU_ITEM_H);
        s.text = text;
        s.flags = (i32)UXR_F_SELECTABLE;
        dd.addChild(s);
        i32 h = (dd.childCount() + (i32)1) * (i32)RKMENU_ITEM_H; // grow the drop-down to hold them
        dd.h = h;
        return s;
        }
    // The number of menus (titles) in a tree.
    static i32 titleCount(UXRscTree* t)
        {
        if (t == (UXRscTree*)0 || t.root == (UXRscObject*)0 || t.root.childCount() < (i32)1)
            {
            return (i32)0;
            }
        return t.root.childAt((i32)0).childCount();
        }
    }
