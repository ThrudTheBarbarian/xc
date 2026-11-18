// GasString.xc — the operands of a GAS string directive.
// =================================================================
//
// `.ascii`, `.asciz` and `.string` take one or more quoted strings separated
// by commas. Inside a string GAS understands \b \f \n \r \t, \\ and \", an
// octal escape of one to three digits (\0, \12, \342) and a hex escape \x
// followed by any number of hex digits, of which the low byte is kept. Any
// other escaped character stands for itself.
//
// Every in-house assembler decodes through here, so they agree. Each used to
// carry its own decoder that knew only a few escapes: \342\200\224 (an em
// dash, as a compiler writes UTF-8) came out as the digits, and \012 as a NUL
// followed by "12".

#import "Foundation.xc"

class GasString
    {
    // The bytes of `rest`, the text after the directive, with a NUL after each
    // string when `zero` (.asciz, .string). Null when `rest` is not a
    // comma-separated list of quoted strings.
    static Data* decode(String* rest, bool zero)
        {
        Data* out = new Data();
        u32 n = rest.byteLength();
        u32 i = GasString.skipSpace(rest, (u32)0);
        if (i >= n)
            return (Data*)0;
        while (true)
            {
            if (i >= n || rest.byteAt(i) != (u8)'"')
                return (Data*)0;
            i = i + (u32)1;
            bool closed = false;
            while (i < n && !closed)
                {
                u8 c = rest.byteAt(i);
                if (c == (u8)'"')
                    {
                    closed = true;
                    i = i + (u32)1;
                    }
                else if (c == (u8)'\\' && i + (u32)1 < n)
                    i = GasString.escape(rest, i + (u32)1, out);
                else
                    {
                    out.appendByte(c);
                    i = i + (u32)1;
                    }
                }
            if (!closed)
                return (Data*)0;
            if (zero)
                out.appendByte((u8)0);
            i = GasString.skipSpace(rest, i);
            if (i >= n)
                return out;
            if (rest.byteAt(i) != (u8)',')
                return (Data*)0;
            i = GasString.skipSpace(rest, i + (u32)1);
            }
        return out;
        }

    // One escape: `i` is just past the backslash. Appends the byte and returns
    // the index after the escape.
    static u32 escape(String* s, u32 i, Data* out)
        {
        u32 n = s.byteLength();
        u8 c = s.byteAt(i);
        if (c >= (u8)'0' && c <= (u8)'7')
            {
            u32 v = (u32)0;
            u32 k = (u32)0;
            while (k < (u32)3 && i < n && s.byteAt(i) >= (u8)'0' && s.byteAt(i) <= (u8)'7')
                {
                v = v * (u32)8 + (u32)(s.byteAt(i) - (u8)'0');
                i = i + (u32)1;
                k = k + (u32)1;
                }
            out.appendByte((u8)(v & (u32)$FF));
            return i;
            }
        if ((c == (u8)'x' || c == (u8)'X') && i + (u32)1 < n && GasString.hexDigit(s.byteAt(i + (u32)1)) >= (i32)0)
            {
            u32 v = (u32)0;
            i = i + (u32)1;
            while (i < n && GasString.hexDigit(s.byteAt(i)) >= (i32)0)
                {
                v = (v << 4) | (u32)GasString.hexDigit(s.byteAt(i));
                i = i + (u32)1;
                }
            out.appendByte((u8)(v & (u32)$FF));
            return i;
            }
        u8 b = c;
        if (c == (u8)'b') b = (u8)8;
        else if (c == (u8)'f') b = (u8)12;
        else if (c == (u8)'n') b = (u8)10;
        else if (c == (u8)'r') b = (u8)13;
        else if (c == (u8)'t') b = (u8)9;
        out.appendByte(b);
        return i + (u32)1;
        }

    static i32 hexDigit(u8 c)
        {
        if (c >= (u8)'0' && c <= (u8)'9') return (i32)(c - (u8)'0');
        if (c >= (u8)'a' && c <= (u8)'f') return (i32)(c - (u8)'a') + (i32)10;
        if (c >= (u8)'A' && c <= (u8)'F') return (i32)(c - (u8)'A') + (i32)10;
        return (i32)-1;
        }

    static u32 skipSpace(String* s, u32 i)
        {
        while (i < s.byteLength() && (s.byteAt(i) == (u8)' ' || s.byteAt(i) == (u8)'\t'))
            i = i + (u32)1;
        return i;
        }
    }
