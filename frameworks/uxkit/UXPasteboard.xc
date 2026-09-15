// UXPasteboard.xc — a typed pasteboard (NSPasteboard in shape); the basis of copy/paste and drag.
//
// A pasteboard holds one payload per TYPE ("public.utf8-plain-text", "public.file-url", an app's own
// UTI) so a copy can offer the same thing several ways and a paste picks the richest it understands.
// A changeCount ticks on every write, the way NSPasteboard lets you notice someone else wrote.  The
// general pasteboard is the clipboard; a fresh one is what a drag session carries.  Data is string-
// typed for now (text, serialized/url payloads); raw bytes are a later addition.
#import "Array.xc"

class UXPasteboardEntry : Object
    {
    u8* type;
    u8* data;
    void init(void)
        {
        type = (u8*)"";
        data = (u8*)"";
        }
    }

    UXPasteboard* gUXGeneralPasteboard;

class UXPasteboard
    {
    Array<UXPasteboardEntry>* entries;
    i32 changeCount;
    void init(void)
        {
        entries = new Array();
        changeCount = (i32)0;
        }

    static UXPasteboard* general(void)
        {
        if (gUXGeneralPasteboard == (UXPasteboard*)0)
            {
            gUXGeneralPasteboard = new UXPasteboard();
            }
        return gUXGeneralPasteboard;
        }
    static bool streq(u8* a, u8* b)
        {
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

    // Clearing is a write: it bumps the change count and drops every type (NSPasteboard semantics).
    void clearContents(void)
        {
        entries.removeAll();
        changeCount = changeCount + (i32)1;
        }

    UXPasteboardEntry* entryForType(u8* type)
        {
        for (u16 i = (u16)0; i < entries.count(); i = i + (u16)1)
            {
            UXPasteboardEntry* e = (UXPasteboardEntry* ?)entries.get(i);
            if (UXPasteboard.streq(e.type, type))
                {
                return e;
                }
            }
        return (UXPasteboardEntry*)0;
        }

    // Write (or overwrite) the payload for a type.  Bumps the change count.
    void setString(u8* s, u8* type)
        {
        UXPasteboardEntry* e = self.entryForType(type);
        if (e == (UXPasteboardEntry*)0)
            {
            e = new UXPasteboardEntry();
            e.type = type;
            entries.add(e);
            }
        e.data = s;
        changeCount = changeCount + (i32)1;
        }
    // Convenience: the plain-text type.
    void writeText(u8* s)
        {
        self.setString(s, (u8*)"public.utf8-plain-text");
        }

    u8* stringForType(u8* type)
        {
        UXPasteboardEntry* e = self.entryForType(type);
        return e == (UXPasteboardEntry*)0 ? (u8*)0 : e.data;
        }
    u8* text(void)
        {
        return self.stringForType((u8*)"public.utf8-plain-text");
        }
    bool hasType(u8* type)
        {
        return self.entryForType(type) != (UXPasteboardEntry*)0;
        }
    i32 typeCount(void)
        {
        return (i32)entries.count();
        }
    u8* typeAt(i32 i)
        { return ((UXPasteboardEntry* ?)entries.get((u16)i)).type;
        }

    // The richer of two types, preferring `a` — richest-first paste in the common two-way case.
    u8* preferredType(u8* a, u8* b)
        {
        if (self.hasType(a))
            {
            return a;
            }
        if (self.hasType(b))
            {
            return b;
            }
        return (u8*)0;
        }
    }
