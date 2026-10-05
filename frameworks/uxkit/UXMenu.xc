// UXMenu.xc — menus.
//
// A menu is a MODEL, not a widget.  GEM's menu_build assembles the OBJECT tree (a bar
// of G_TITLEs plus a dropdown G_BOX of G_STRINGs per title), menu_bar draws it, and the
// bar click is intercepted INSIDE evnt_multi — so the pull-down tracking, the hover
// highlight, the hit-test and the redraw are all GEM's.  The app simply receives an
// MN_SELECTED message.
//
// So UXMenu contains no drawing, no tracking and no hit-testing.  It describes what the
// menu IS, hands that to GEM, and turns the resulting message back into a bound method
// call.  Same bargain as UXButton (no drawing) and UXTextField (no text editing).

#import "UXControl.xc"
#import "UXViewDriver.xc"
#import "Array.xc"

class UXMenuItem : Object
    {
    u8* title;
    bool isSeparator;
    bool enabled;
    bool checked;
    u8 key;        // the shortcut's key, an uppercase letter or a punctuation mark; 0 = none
    bool keyShift; // the shortcut also needs Shift
    callback action void(UXMenuItem* sender); // a menu never owns its controller

    void init(void)
        {
        title = "";
        isSeparator = false;
        enabled = true;
        checked = false;
        key = (u8)0;
        keyShift = false;
        action = (callback void(UXMenuItem * sender))0;
        }

    // A keyboard shortcut: the platform's command key (Command on macOS and iOS, Control
    // elsewhere) with `k`, and Shift as well when `shift`.  A letter is given in upper case.
    // Returns the item, so a menu can be written item.setShortcut(...) in one line.
    UXMenuItem* setShortcut(u8 k, bool shift)
        {
        key = k >= (u8)'a' && k <= (u8)'z' ? (u8)(k - (u8)32) : k;
        keyShift = shift;
        return self;
        }

    void setAction(callback a void(UXMenuItem* sender))
        {
        action = a;
        }
    void fire(void)
        {
        if (action)
            {
            action(self);
            }
        }

    // The string GEM wants, with its marker byte:
    //   "-"        a separator
    //   \x01 s     pre-ticked
    //   \x02 s     greyed + non-selectable
    //   s \t [+] k  a shortcut, after the title (see setShortcut)
    u8* encoded(void)
        {
        if (isSeparator)
            {
            return "-";
            }
        if (enabled && !checked && key == (u8)0)
            {
            return title;
            }
        u16 n = (u16)0;
        while (title[n] != (u8)0)
            {
            n = n + (u16)1;
            }
        u8* b = (u8*)malloc((u32)n + (u32)6);
        u16 at = (u16)0;
        if (!enabled || checked)
            {
            b[0] = checked ? (u8)1 : (u8)2; // MENU_CHECK / MENU_DISABLE
            at = (u16)1;
            }
        for (u16 i = (u16)0; i < n; i++)
            {
            b[at] = title[i];
            at = at + (u16)1;
            }
        // the shortcut: a tab, "+" for Shift, then the key (UXMenuKey reads it back)
        if (key != (u8)0)
            {
            b[at] = (u8)9;
            at = at + (u16)1;
            if (keyShift)
                {
                b[at] = (u8)'+';
                at = at + (u16)1;
                }
            b[at] = key;
            at = at + (u16)1;
            }
        b[at] = (u8)0;
        return b;
        }
    }

    class UXMenu : Object
    {
    u8* title;
    Array<UXMenuItem>* items;

    void init(void)
        {
        title = "";
        items = new Array();
        }

    UXMenuItem* addItem(u8* t, callback a void(UXMenuItem* sender))
        {
        UXMenuItem* it = new UXMenuItem();
        it.title = t;
        it.setAction(a);
        items.add(it);
        return it;
        }
    void addSeparator(void)
        {
        UXMenuItem* it = new UXMenuItem();
        it.isSeparator = true;
        items.add(it);
        }
    }

    class UXMenuBar : Object
    {
    Array<UXMenu>* menus;
    pointer tree; // the OBJECT tree menu_build gave us; GEM owns its contents

    void init(void)
        {
        menus = new Array();
        tree = (pointer)0;
        }

    UXMenu* addMenu(u8* title)
        {
        UXMenu* m = new UXMenu();
        m.title = title;
        menus.add(m);
        return m;
        }

    // Hand the model to GEM and show the bar.  From here on the bar is GEM's problem.
    void install(i32 screenW)
        {
        u16 n = menus.count();
        if (n == (u16)0)
            {
            return;
            }

        // UXMenuDef[] = { const char *title; const char **items; int nitems } — neutral, and
        // laid out to match GEM's menu_def so the GEM driver reads it directly.
        pointer defs = malloc((u32)n * (u32)sizeof(UXMenuDef));
        UXMenuDef* d = (UXMenuDef*)defs;

        for (u16 i = (u16)0; i < n; i++)
            {
            UXMenu* m = (UXMenu* ?)menus.get(i);
            u16 ni = m.items.count();
            pointer strs = malloc((u32)ni * (u32)sizeof(pointer)); // char*[] — pointer-width, NOT 4
                                                                   // (a 4 here is a 2x heap overflow
                                                                   // on 64-bit: corrupts adjacent heap)
            u8** sv = (u8**)strs;
            for (u16 j = (u16)0; j < ni; j++)
                {
                UXMenuItem* it = (UXMenuItem* ?)m.items.get(j);
                sv[j] = it.encoded();
                }
            d[i].title = m.title;
            d[i].items = (u8**)strs;
            d[i].nitems = (i32)ni;
            }

        tree = gDriver.menuBuild((pointer)defs, (i32)n, screenW);
        gDriver.menuShow(tree, (i32)1);
        }

    // MN_SELECTED: msg[3] = title OBJECT index, msg[4] = item OBJECT index.
    // Decode as the header says: title ordinal = msg[3]-2, and GEM turns the item
    // object index into an ordinal for us.  Separators never fire.
    void handleSelection(i32 titleObj, i32 itemObj)
        {
        i32 t = titleObj - (i32)2;
        if (t < (i32)0 || t >= (i32)menus.count())
            {
            return;
            }
        i32 i = gDriver.menuItemOrd(tree, t, itemObj);
        if (i < (i32)0)
            {
            return;
            }

        UXMenu* m = (UXMenu* ?)menus.get((u16)t);
        if (i >= (i32)m.items.count())
            {
            return;
            }
        UXMenuItem* it = (UXMenuItem* ?)m.items.get((u16)i);
        it.fire();
        }

    // A key press, offered to the menus before the key window gets it: true if it was an item's
    // shortcut, which then fired.  The command key arrives as Control in ev.modifiers, or as a
    // control code (Control-Z is $1A); Shift is in ev.modifiers.  A backend whose native menus
    // handle their shortcuts (AppKit, GTK, the web page) consumes the key before it gets here.
    bool performShortcut(UXEvent* ev)
        {
        u8 c = (u8)((i32)ev.key & (i32)UX_KEY_ASCII);
        if (((i32)ev.modifiers & (i32)UX_MOD_CTRL) == (i32)0)
            {
            return false;
            }
        if (c >= (u8)1 && c <= (u8)26)
            {
            c = (u8)(c + (u8)64);
            }
        else if (c >= (u8)'a' && c <= (u8)'z')
            {
            c = (u8)(c - (u8)32);
            }
        bool shift = ((i32)ev.modifiers & (i32)UX_MOD_SHIFT) != (i32)0;
        for (u16 m = (u16)0; m < menus.count(); m++)
            {
            UXMenu* mn = (UXMenu* ?)menus.get(m);
            for (u16 i = (u16)0; i < mn.items.count(); i++)
                {
                UXMenuItem* it = (UXMenuItem* ?)mn.items.get(i);
                if (it.key != (u8)0 && it.key == c && it.keyShift == shift && it.enabled && !it.isSeparator)
                    {
                    it.fire();
                    return true;
                    }
                }
            }
        return false;
        }

    // Reflect model state back into the live menu.  GEM redraws.
    void setChecked(u16 mi, u16 ii, bool on)
        {
        UXMenu* m = (UXMenu* ?)menus.get(mi);
        UXMenuItem* it = (UXMenuItem* ?)m.items.get(ii);
        it.checked = on;
        gDriver.menuCheck(tree, (i32)mi, (i32)ii, on ? (i32)1 : (i32)0);
        }
    void setEnabled(u16 mi, u16 ii, bool on)
        {
        UXMenu* m = (UXMenu* ?)menus.get(mi);
        UXMenuItem* it = (UXMenuItem* ?)m.items.get(ii);
        it.enabled = on;
        gDriver.menuEnable(tree, (i32)mi, (i32)ii, on ? (i32)1 : (i32)0);
        }
    }
