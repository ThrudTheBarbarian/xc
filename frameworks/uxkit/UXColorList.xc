// UXColorList.xc — a named colour list / semantic theme (NSColorList + AppKit semantic colours).
//
// Colours by name, so widgets read "windowBackground" / "accent" / "text" from a theme instead of
// hardcoding VDI pens — swap the theme and the whole UI restyles.  defaultTheme() ships the standard
// semantic set; an app can override any entry or build its own list.  Composes with UXColor.
#import "Array.xc"
#import "UXColor.xc"

class UXColorEntry : Object
    {
    u8* name;
    UXColor* color;
    void init(void)
        {
        name = (u8*)"";
        color = (UXColor*)0;
        }
    }

    UXColorList* gUXDefaultTheme;

class UXColorList
    {
    Array<UXColorEntry>* entries;
    void init(void)
        {
        entries = new Array();
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

    void set(u8* name, UXColor* color)
        {
        for (u16 i = (u16)0; i < entries.count(); i = i + (u16)1)
            {
            UXColorEntry* e = (UXColorEntry* ?)entries.get(i);
            if (UXColorList.streq(e.name, name))
                {
                e.color = color;
                return;
                }
            }
        UXColorEntry* e = new UXColorEntry();
        e.name = name;
        e.color = color;
        entries.add(e);
        }
    bool has(u8* name)
        {
        for (u16 i = (u16)0; i < entries.count(); i = i + (u16)1)
            {
            if (UXColorList.streq(((UXColorEntry* ?)entries.get(i)).name, name))
                {
                return true;
                }
            }
        return false;
        }
    // Look up a colour by name; returns `fallback` (or black) if absent.
    UXColor* colorOr(u8* name, UXColor* fallback)
        {
        for (u16 i = (u16)0; i < entries.count(); i = i + (u16)1)
            {
            UXColorEntry* e = (UXColorEntry* ?)entries.get(i);
            if (UXColorList.streq(e.name, name))
                {
                return e.color;
                }
            }
        return fallback == (UXColor*)0 ? UXColor.black() : fallback;
        }
    UXColor* color(u8* name)
        {
        return self.colorOr(name, UXColor.black());
        }
    i32 count(void)
        {
        return (i32)entries.count();
        }

    // The standard semantic theme (grey GEM/AppKit-ish palette).
    static UXColorList* defaultTheme(void)
        {
        if (gUXDefaultTheme != (UXColorList*)0)
            {
            return gUXDefaultTheme;
            }
        UXColorList* t = new UXColorList();
        t.set((u8*)"windowBackground", UXColor.rgb((i32)216, (i32)216, (i32)216));
        t.set((u8*)"controlFace", UXColor.rgb((i32)192, (i32)192, (i32)192));
        t.set((u8*)"controlShadow", UXColor.rgb((i32)128, (i32)128, (i32)128));
        t.set((u8*)"controlHighlight", UXColor.white());
        t.set((u8*)"text", UXColor.black());
        t.set((u8*)"disabledText", UXColor.rgb((i32)144, (i32)144, (i32)144));
        t.set((u8*)"accent", UXColor.rgb((i32)0, (i32)122, (i32)255));
        t.set((u8*)"selectionFill", UXColor.rgb((i32)179, (i32)215, (i32)255)); // the pen-250 blue
        t.set((u8*)"selectedText", UXColor.black());
        t.set((u8*)"separator", UXColor.rgb((i32)160, (i32)160, (i32)160));
        gUXDefaultTheme = t;
        return t;
        }
    }
