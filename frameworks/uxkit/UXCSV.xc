// UXCSV.xc — a CSV parser + serializer (RFC 4180-style), for tabular import/export.
//
// Parses text into rows of string fields, honouring quoted fields ("...") that may contain commas,
// newlines and doubled "" quotes; serialises rows back, quoting a field only when it needs it.  The
// tabular counterpart to UXJSON — what the multi-column list view loads/saves and what a data import
// reads.  Pure string work, fully testable.
#import "Array.xc"

class UXCSVField : Object
    {
    u8* s;
    void init(void)
        {
        s = (u8*)"";
        }
    } class UXCSVRow : Object
    {
    Array<UXCSVField>* fields;
    void init(void)
        {
        fields = new Array();
        }
    i32 count(void)
        {
        return (i32)fields.count();
        }
    u8* field(i32 i)
        { return ((UXCSVField* ?)fields.get((u16)i)).s;
        }
    void add(u8* s)
        {
        UXCSVField* f = new UXCSVField();
        f.s = s;
        fields.add(f);
        }
    }

    class UXCSV
    {
    static i32 slen(u8* s)
        {
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }
    static u8* dup(u8* s, i32 start, i32 len)
        {
        u8* o = new u8[(u32)(len + (i32)1)];
        for (i32 i = (i32)0; i < len; i = i + (i32)1)
            {
            o[i] = s[start + i];
            }
        o[len] = (u8)0;
        return o;
        }
    static bool needsQuote(u8* s)
        {
        i32 i = (i32)0;
        while (s[i] != (u8)0)
            {
            u8 c = s[i];
            if (c == (u8)',' || c == (u8)'"' || c == (u8)10 || c == (u8)13)
                {
                return true;
                }
            i = i + (i32)1;
            }
        return false;
        }

    // ---- parse ---------------------------------------------------------------
    static Array<UXCSVRow>* parse(u8* text)
        {
        Array<UXCSVRow>* rows = new Array();
        i32 n = UXCSV.slen(text);
        i32 i = (i32)0;
        while (i < n)
            {
            UXCSVRow* row = new UXCSVRow();
            bool more = true;
            while (more)
                {
                i32 endBox[1];
                endBox[0] = i;
                u8* f = UXCSV.parseField(text, n, &endBox[0]);
                i = endBox[0];
                row.add(f);
                // another field
                if (i < n && text[i] == (u8)',')
                    {
                    i = i + (i32)1;
                    }
                else
                    {
                    more = false;
                    }
                }
            rows.add(row);
            // consume the row terminator (\n, \r, or \r\n)
            if (i < n && text[i] == (u8)13)
                {
                i = i + (i32)1;
                }
            if (i < n && text[i] == (u8)10)
                {
                i = i + (i32)1;
                }
            }
        return rows;
        }
    // parse one field starting at *pi; advance *pi past it (but not past the , or newline).
    static u8* parseField(u8* text, i32 n, i32* pi)
        {
        i32 i = pi[0];
        if (i < n && text[i] == (u8)'"')
            {
            i = i + (i32)1; // opening quote
            // measure the unescaped length
            i32 outlen = (i32)0;
            i32 j = i;
            while (j < n)
                {
                if (text[j] == (u8)'"')
                    {
                    if (j + (i32)1 < n && text[j + (i32)1] == (u8)'"')
                        {
                        outlen = outlen + (i32)1;
                        j = j + (i32)2;
                        }
                    else
                        {
                        break;
                        }
                    }
                else
                    {
                    outlen = outlen + (i32)1;
                    j = j + (i32)1;
                    }
                }
            u8* buf = new u8[(u32)(outlen + (i32)1)];
            i32 w = (i32)0;
            i32 k = i;
            while (k < n)
                {
                if (text[k] == (u8)'"')
                    {
                    if (k + (i32)1 < n && text[k + (i32)1] == (u8)'"')
                        {
                        buf[w] = (u8)'"';
                        w = w + (i32)1;
                        k = k + (i32)2;
                        }
                    // consume closing quote
                    else
                        {
                        k = k + (i32)1;
                        break;
                        }
                    }
                else
                    {
                    buf[w] = text[k];
                    w = w + (i32)1;
                    k = k + (i32)1;
                    }
                }
            buf[w] = (u8)0;
            pi[0] = k;
            return buf;
            }
        // unquoted: to the next comma or newline
        i32 start = i;
        while (i < n && text[i] != (u8)',' && text[i] != (u8)10 && text[i] != (u8)13)
            {
            i = i + (i32)1;
            }
        pi[0] = i;
        return UXCSV.dup(text, start, i - start);
        }

    // ---- serialize (two-pass) ------------------------------------------------
    static u8* serialize(Array<UXCSVRow>* rows)
        {
        i32 total = UXCSV.measureAll(rows);
        u8* o = new u8[(u32)(total + (i32)1)];
        i32 p = (i32)0;
        for (u16 r = (u16)0; r < rows.count(); r = r + (u16)1)
            {
            UXCSVRow* row = (UXCSVRow* ?)rows.get(r);
            for (i32 c = (i32)0; c < row.count(); c = c + (i32)1)
                {
                if (c > (i32)0)
                    {
                    o[p] = (u8)',';
                    p = p + (i32)1;
                    }
                p = UXCSV.emitField(o, p, row.field(c));
                }
            if (r < rows.count() - (u16)1)
                {
                o[p] = (u8)10;
                p = p + (i32)1;
                }
            }
        o[p] = (u8)0;
        return o;
        }
    static i32 measureAll(Array<UXCSVRow>* rows)
        {
        i32 t = (i32)1;
        for (u16 r = (u16)0; r < rows.count(); r = r + (u16)1)
            {
            UXCSVRow* row = (UXCSVRow* ?)rows.get(r);
            for (i32 c = (i32)0; c < row.count(); c = c + (i32)1)
                {
                if (c > (i32)0)
                    {
                    t = t + (i32)1;
                    }
                u8* f = row.field(c);
                t = t + UXCSV.slen(f);
                // quotes + doubling
                if (UXCSV.needsQuote(f))
                    {
                    t = t + (i32)2 + UXCSV.countQuotes(f);
                    }
                }
            t = t + (i32)1; // newline
            }
        return t;
        }
    static i32 countQuotes(u8* s)
        {
        i32 n = (i32)0;
        i32 i = (i32)0;
        while (s[i] != (u8)0)
            {
            if (s[i] == (u8)'"')
                {
                n = n + (i32)1;
                }
            i = i + (i32)1;
            }
        return n;
        }
    static i32 emitField(u8* o, i32 p, u8* f)
        {
        if (!UXCSV.needsQuote(f))
            {
            i32 i = (i32)0;
            while (f[i] != (u8)0)
                {
                o[p] = f[i];
                p = p + (i32)1;
                i = i + (i32)1;
                }
            return p;
            }
        o[p] = (u8)'"';
        p = p + (i32)1;
        i32 i = (i32)0;
        while (f[i] != (u8)0)
            {
            if (f[i] == (u8)'"')
                {
                o[p] = (u8)'"';
                p = p + (i32)1;
                }
            o[p] = f[i];
            p = p + (i32)1;
            i = i + (i32)1;
            }
        o[p] = (u8)'"';
        p = p + (i32)1;
        return p;
        }
    }
