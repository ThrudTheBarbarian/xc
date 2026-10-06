// UXTextStyle.xc — how a span of rich text is drawn.  Rich text is a Foundation AttributedString;
// the attributes UXKit gives a meaning to are "bold", "italic", "underline" and "monospace" (Number
// booleans), "pen" (the colour pen, a Number; 1 = ink), "color" (a Number, 0xRRGGBB; none means the
// view's ink), "size" (the point size, a Number; 0 = the view's own) and "alignment" (a Number,
// UX_ALIGN_*, which a text view applies to the whole paragraph).  This reads them as one value, for
// measuring and drawing a run, and sets them over a range.
#import "AttributedString.xc"
#import "Number.xc"

class UXTextStyle : Object
    {
    bool bold;
    bool italic;
    bool underline;
    bool monospace;
    i32 pen;
    i32 color; // 0xRRGGBB, or -1 for the view's ink
    i16 size;
    i32 alignment;
    void init(void)
        {
        bold = false;
        italic = false;
        underline = false;
        monospace = false;
        pen = (i32)1;
        color = (i32)-1;
        size = (i16)0;
        alignment = (i32)0;
        }
    // The style an attribute set describes; names it does not have keep their defaults.
    static UXTextStyle* of(Map* attrs)
        {
        UXTextStyle* s = new UXTextStyle();
        if (attrs == (Map*)0)
            {
            return s;
            }
        Number* b = (Number* ?)attrs.get(String.withCString((u8*)"bold"));
        if (b != (Number*)0)
            {
            s.bold = b.asBool();
            }
        Number* it = (Number* ?)attrs.get(String.withCString((u8*)"italic"));
        if (it != (Number*)0)
            {
            s.italic = it.asBool();
            }
        Number* u = (Number* ?)attrs.get(String.withCString((u8*)"underline"));
        if (u != (Number*)0)
            {
            s.underline = u.asBool();
            }
        Number* mo = (Number* ?)attrs.get(String.withCString((u8*)"monospace"));
        if (mo != (Number*)0)
            {
            s.monospace = mo.asBool();
            }
        Number* c = (Number* ?)attrs.get(String.withCString((u8*)"color"));
        if (c != (Number*)0)
            {
            i32 cv = c.value();
            s.color = cv;
            }
        Number* al = (Number* ?)attrs.get(String.withCString((u8*)"alignment"));
        if (al != (Number*)0)
            {
            i32 av = al.value();
            s.alignment = av;
            }
        Number* p = (Number* ?)attrs.get(String.withCString((u8*)"pen"));
        if (p != (Number*)0)
            {
            i32 pv = p.value();
            s.pen = pv;
            }
        Number* z = (Number* ?)attrs.get(String.withCString((u8*)"size"));
        if (z != (Number*)0)
            {
            i16 zv = z.value();
            s.size = zv;
            }
        return s;
        }
    // The style of the byte at `i`.
    static UXTextStyle* at(AttributedString* as, i32 i)
        {
        return UXTextStyle.of(as.attributesAt(i));
        }
    bool sameAs(UXTextStyle* o)
        {
        return o != (UXTextStyle*)0 && bold == o.bold && italic == o.italic && underline == o.underline &&
               monospace == o.monospace && pen == o.pen && color == o.color && size == o.size && alignment == o.alignment;
        }
    static void setBold(AttributedString* as, bool v, i32 start, i32 len)
        {
        as.setAttribute(String.withCString((u8*)"bold"), Number.withBool(v), Range.make(start, len));
        }
    static void setItalic(AttributedString* as, bool v, i32 start, i32 len)
        {
        as.setAttribute(String.withCString((u8*)"italic"), Number.withBool(v), Range.make(start, len));
        }
    static void setPen(AttributedString* as, i32 pen, i32 start, i32 len)
        {
        as.setAttribute(String.withCString((u8*)"pen"), Number.with(pen), Range.make(start, len));
        }
    static void setSize(AttributedString* as, i16 size, i32 start, i32 len)
        {
        as.setAttribute(String.withCString((u8*)"size"), Number.with(size), Range.make(start, len));
        }
    static void setUnderline(AttributedString* as, bool v, i32 start, i32 len)
        {
        as.setAttribute(String.withCString((u8*)"underline"), Number.withBool(v), Range.make(start, len));
        }
    static void setMonospace(AttributedString* as, bool v, i32 start, i32 len)
        {
        as.setAttribute(String.withCString((u8*)"monospace"), Number.withBool(v), Range.make(start, len));
        }
    // 0xRRGGBB; -1 takes the colour off, back to the view's ink
    static void setColor(AttributedString* as, i32 rgb, i32 start, i32 len)
        {
        if (rgb < (i32)0)
            {
            as.removeAttribute(String.withCString((u8*)"color"), Range.make(start, len));
            return;
            }
        as.setAttribute(String.withCString((u8*)"color"), Number.with(rgb), Range.make(start, len));
        }
    static void setAlignment(AttributedString* as, i32 align, i32 start, i32 len)
        {
        as.setAttribute(String.withCString((u8*)"alignment"), Number.with(align), Range.make(start, len));
        }
    }
