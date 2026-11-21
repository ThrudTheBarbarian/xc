// NumLit.xc — the integer literal the assemblers read, scanned in one place
// (#336). Each assembler kept its own copy, and they had drifted in which
// prefixes they took and how far they read; this is the one scanner, and each
// keeps only its own choices: which prefixes its syntax has, whether a `+`
// sign is allowed, and whether the literal must be all of its operand.
#import "Foundation.xc"
#import "NumLitDefs.xc"

class NumLit
{
    // From s[from]: an optional sign, then `0x`/`0X` hex (the two characters
    // are taken whether or not a digit follows, as strtoll takes them), or a
    // prefix `opts` allows, else decimal; then digits of that base up to the
    // first that is not one. The magnitude is kept modulo 2^64. Returns how
    // many digits were read (0 for none); *end is the index after the last.
    static u32 scan(String* s, u32 from, u32 opts, u64* mag, bool* neg, u32* end)
    {
        u32 n = s.byteLength();
        u32 i = from;
        *neg = false;
        *mag = (u64)0;
        if (i < n && s.byteAt(i) == (u8)'-')
        {
            *neg = true;
            i = i + (u32)1;
        }
        else if (i < n && s.byteAt(i) == (u8)'+' && (opts & (u32)NUM_NOPLUS) == (u32)0)
            i = i + (u32)1;
        u64 base = (u64)10;
        if (i + (u32)1 < n && s.byteAt(i) == (u8)'0' && (s.byteAt(i + (u32)1) == (u8)'x' || s.byteAt(i + (u32)1) == (u8)'X'))
        {
            base = (u64)16;
            i = i + (u32)2;
        }
        else if (i < n && s.byteAt(i) == (u8)'$' && (opts & (u32)NUM_DOLLAR) != (u32)0)
        {
            base = (u64)16;
            i = i + (u32)1;
        }
        else if (i < n && s.byteAt(i) == (u8)'%' && (opts & (u32)NUM_PERCENT) != (u32)0)
        {
            base = (u64)2;
            i = i + (u32)1;
        }
        else if (i < n && s.byteAt(i) == (u8)'0' && (opts & (u32)NUM_OCTAL) != (u32)0)
            base = (u64)8;
        u32 digits = (u32)0;
        u64 v = (u64)0;
        while (i < n)
        {
            u8 c = s.byteAt(i);
            u64 d = (u64)16;
            if (c >= (u8)'0' && c <= (u8)'9')
                d = (u64)(c - (u8)'0');
            else if (c >= (u8)'a' && c <= (u8)'f')
                d = (u64)(c - (u8)'a') + (u64)10;
            else if (c >= (u8)'A' && c <= (u8)'F')
                d = (u64)(c - (u8)'A') + (u64)10;
            if (d >= base)
                break;
            v = v * base + d;
            digits = digits + (u32)1;
            i = i + (u32)1;
        }
        *mag = v;
        *end = i;
        return digits;
    }
}
