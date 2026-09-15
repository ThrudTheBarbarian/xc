// UXFont.xc — a font descriptor value (NSFont/NSFontDescriptor in shape).
//
// Family, point size, and the bold/italic traits, with immutable derivations (withSize, bold(),
// toggling a trait) the way NSFont vends variants.  This is the value a font chooser edits and text
// drawing carries; the actual glyph rendering + the list of available families are backend business.
#import "Array.xc"

class UXFont
    {
    u8* family;
    i16 size;
    bool bold;
    bool italic;
    void init(void)
        {
        family = (u8*)"System";
        size = (i16)12;
        bold = false;
        italic = false;
        }

    static UXFont* make(u8* family, i16 size)
        {
        UXFont* f = new UXFont();
        f.family = family;
        f.size = size;
        return f;
        }
    static UXFont* makeTraits(u8* family, i16 size, bool bold, bool italic)
        {
        UXFont* f = UXFont.make(family, size);
        f.bold = bold;
        f.italic = italic;
        return f;
        }
    UXFont* dup(void)
        {
        return UXFont.makeTraits(family, size, bold, italic);
        }

    UXFont* withSize(i16 s)
        {
        UXFont* f = self.dup();
        f.size = s;
        return f;
        }
    UXFont* withFamily(u8* fam)
        {
        UXFont* f = self.dup();
        f.family = fam;
        return f;
        }
    UXFont* bolded(void)
        {
        UXFont* f = self.dup();
        f.bold = true;
        return f;
        }
    UXFont* unbolded(void)
        {
        UXFont* f = self.dup();
        f.bold = false;
        return f;
        }
    UXFont* italicized(void)
        {
        UXFont* f = self.dup();
        f.italic = true;
        return f;
        }
    UXFont* togglingBold(void)
        {
        UXFont* f = self.dup();
        f.bold = !bold;
        return f;
        }
    UXFont* togglingItalic(void)
        {
        UXFont* f = self.dup();
        f.italic = !italic;
        return f;
        }
    UXFont* scaledBy(i16 pct)
        {
        UXFont* f = self.dup();
        f.size = (i16)((i32)size * (i32)pct / (i32)100);
        return f;
        }

    bool isBold(void)
        {
        return bold;
        }
    bool isItalic(void)
        {
        return italic;
        }
    bool isEqualTo(UXFont* o)
        {
        if (o == (UXFont*)0)
            {
            return false;
            }
        return size == o.size && bold == o.bold && italic == o.italic && UXFont.streq(family, o.family);
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

    // "Helvetica 12 Bold Italic" — a chooser preview / menu label.
    u8* description(void)
        {
        i32 fl = UXFont.slen(family);
        u8* out = new u8[(u32)(fl + (i32)32)];
        i32 o = (i32)0;
        for (i32 i = (i32)0; i < fl; i = i + (i32)1)
            {
            out[o] = family[i];
            o = o + (i32)1;
            }
        out[o] = (u8)' ';
        o = o + (i32)1;
        o = self.putNum(out, o, (i32)size);
        if (bold)
            {
            o = self.putStr(out, o, (u8*)" Bold");
            }
        if (italic)
            {
            o = self.putStr(out, o, (u8*)" Italic");
            }
        out[o] = (u8)0;
        return out;
        }
    static i32 slen(u8* s)
        {
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }
    i32 putNum(u8* out, i32 o, i32 v)
        {
        u8 tmp[8];
        i32 t = (i32)0;
        i32 x = v < (i32)0 ? -v : v;
        if (x == (i32)0)
            {
            tmp[0] = (u8)'0';
            t = (i32)1;
            }
        while (x > (i32)0)
            {
            tmp[t] = (u8)((i32)'0' + x % (i32)10);
            x = x / (i32)10;
            t = t + (i32)1;
            }
        for (i32 i = (i32)0; i < t; i = i + (i32)1)
            {
            out[o] = tmp[t - (i32)1 - i];
            o = o + (i32)1;
            }
        return o;
        }
    i32 putStr(u8* out, i32 o, u8* s)
        {
        i32 i = (i32)0;
        while (s[i] != (u8)0)
            {
            out[o] = s[i];
            o = o + (i32)1;
            i = i + (i32)1;
            }
        return o;
        }
    }
