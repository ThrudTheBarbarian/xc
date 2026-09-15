// UXAttributedString.xc — text carrying per-range attributes (NSAttributedString in shape).
//
// A string plus, for each character, a small attribute record (bold, italic, colour pen, point size).
// Applying an attribute over a range sets those characters; querying reads a character's attributes;
// and the string coalesces equal neighbours into RUNS so drawing can stroke one styled span at a time
// (NSAttributedString's model).  Per-character storage keeps set/query trivial and correct; runs are
// derived on demand.  This is the model behind styled canvas text and a rich-text field.
#import "Array.xc"
#import "UXRange.xc" // a run is a range with a style attached

class UXCharAttr : Object
    {
    bool bold;
    bool italic;
    i32 pen;  // colour pen (default 1 = ink)
    i16 size; // point size (0 = default)
    void init(void)
        {
        bold = false;
        italic = false;
        pen = (i32)1;
        size = (i16)0;
        }
    UXCharAttr* dup(void)
        {
        UXCharAttr* c = new UXCharAttr();
        c.bold = bold;
        c.italic = italic;
        c.pen = pen;
        c.size = size;
        return c;
        }
    bool sameAs(UXCharAttr* o)
        {
        return bold == o.bold && italic == o.italic && pen == o.pen && size == o.size;
        }
    }

    // A run of characters sharing one style: a range, plus the style.  Extends UXRange rather than
    // respelling the pair — same idea, same field names, everywhere in the toolkit.
    class UXAttrRun : UXRange
    {
    UXCharAttr* attr;
    void init(void)
        {
        super.init();
        attr = (UXCharAttr*)0;
        }
    }

    class UXAttributedString
    {
    u8* text;
    i32 len;
    Array<UXCharAttr>* attrs; // one UXCharAttr per character
    void init(void)
        {
        text = (u8*)"";
        len = (i32)0;
        attrs = new Array();
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
    static UXAttributedString* make(u8* s)
        {
        UXAttributedString* a = new UXAttributedString();
        a.text = s;
        a.len = UXAttributedString.slen(s);
        for (i32 i = (i32)0; i < a.len; i = i + (i32)1)
            {
            a.attrs.add(new UXCharAttr());
            }
        return a;
        }
    // not `string` — that is a reserved word in xtc
    u8* stringValue(void)
        {
        return text;
        }
    i32 length(void)
        {
        return len;
        }
    UXCharAttr* attributesAt(i32 i)
        {
        if (i < (i32)0 || i >= len)
            {
            return new UXCharAttr();
            }
        return (UXCharAttr* ?)attrs.get((u16)i);
        }

    // clamp a range to the string and visit each character's attribute record
    i32 clampStart(i32 start)
        {
        return start < (i32)0 ? (i32)0 : start;
        }
    i32 clampEnd(i32 start, i32 length)
        {
        i32 e = start + length;
        return e > len ? len : e;
        }

    void setBold(bool v, i32 start, i32 length)
        {
        i32 s = self.clampStart(start);
        i32 e = self.clampEnd(start, length);
        for (i32 i = s; i < e; i = i + (i32)1)
            {
            self.attributesAt(i).bold = v;
            }
        }
    void setItalic(bool v, i32 start, i32 length)
        {
        i32 s = self.clampStart(start);
        i32 e = self.clampEnd(start, length);
        for (i32 i = s; i < e; i = i + (i32)1)
            {
            self.attributesAt(i).italic = v;
            }
        }
    void setColor(i32 pen, i32 start, i32 length)
        {
        i32 s = self.clampStart(start);
        i32 e = self.clampEnd(start, length);
        for (i32 i = s; i < e; i = i + (i32)1)
            {
            self.attributesAt(i).pen = pen;
            }
        }
    void setSize(i16 size, i32 start, i32 length)
        {
        i32 s = self.clampStart(start);
        i32 e = self.clampEnd(start, length);
        for (i32 i = s; i < e; i = i + (i32)1)
            {
            self.attributesAt(i).size = size;
            }
        }

    // Coalesce equal-attribute neighbours into runs (for drawing a styled span at a time).
    Array<UXAttrRun>* runs(void)
        {
        Array<UXAttrRun>* out = new Array();
        if (len == (i32)0)
            {
            return out;
            }
        i32 runStart = (i32)0;
        UXCharAttr* cur = self.attributesAt((i32)0);
        for (i32 i = (i32)1; i < len; i = i + (i32)1)
            {
            UXCharAttr* a = self.attributesAt(i);
            if (!a.sameAs(cur))
                {
                UXAttrRun* r = new UXAttrRun();
                r.loc = runStart;
                r.len = i - runStart;
                r.attr = cur.dup();
                out.add(r);
                runStart = i;
                cur = a;
                }
            }
        UXAttrRun* r = new UXAttrRun();
        r.loc = runStart;
        r.len = len - runStart;
        r.attr = cur.dup();
        out.add(r);
        return out;
        }
    i32 runCount(void)
        {
        return (i32)self.runs().count();
        }
    }
