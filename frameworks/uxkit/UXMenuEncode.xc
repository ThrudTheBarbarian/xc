// UXMenuEncode.xc — an app's menus as ONE string, for the mobile drivers' native menus.
//
// A phone or a tablet has no menu bar: iOS shows the app's menus from a "more" button as a UIMenu,
// Android from an overflow button as a PopupMenu, each with a submenu per title.  Both shims build
// those from this string, which is the UXMenuDef list as it stands: for each title, the title, then
// each item after a US (0x1f), and an RS (0x1e) closing the title.  Items keep UXKit's own markers,
// which the shims read: "-" a separator, a leading 0x01 checked, a leading 0x02 disabled.
#import "UXViewDriver.xc"

#define UX_MENU_ENC_CAP 8192

u8 gUXMenuEnc[8192];

class UXMenuEncode
    {
    static i32 put(i32 at, u8* s)
        {
        i32 i = (i32)0;
        while (s[i] != (u8)0 && at < (i32)UX_MENU_ENC_CAP - (i32)2)
            {
            gUXMenuEnc[at] = s[i];
            at = at + (i32)1;
            i = i + (i32)1;
            }
        return at;
        }
    static i32 putByte(i32 at, u8 b)
        {
        if (at < (i32)UX_MENU_ENC_CAP - (i32)2)
            {
            gUXMenuEnc[at] = b;
            at = at + (i32)1;
            }
        return at;
        }
    // The encoding of n titles' definitions, NUL-terminated, in a buffer of its own (kept until the
    // next call).
    static u8* encode(pointer defs, i32 n)
        {
        UXMenuDef* d = (UXMenuDef*)defs;
        i32 at = (i32)0;
        for (i32 t = (i32)0; t < n; t = t + (i32)1)
            {
            at = UXMenuEncode.put(at, d[t].title);
            u8** items = d[t].items;
            for (i32 j = (i32)0; j < d[t].nitems; j = j + (i32)1)
                {
                at = UXMenuEncode.putByte(at, (u8)$1F);
                at = UXMenuEncode.put(at, UXMenuKey.title(items[j])); // no shortcuts on a device
                }
            at = UXMenuEncode.putByte(at, (u8)$1E);
            }
        gUXMenuEnc[at] = (u8)0;
        return &gUXMenuEnc[(i32)0];
        }
    }
