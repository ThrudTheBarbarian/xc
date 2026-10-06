// UXMarkdown.xc — a tiny inline-markdown renderer to a Foundation AttributedString.
//
// Turns **bold**, *italic* and `code` markers into an attributed string: the marker characters are
// stripped and the spans they wrapped carry the bold / italic / code attributes.  Enough for help
// text, notes and formatted labels drawn through the attributed-string path; block markdown (headings,
// lists) would layer on top.  Pure string work, testable.
#import "Array.xc"
#import "UXTextStyle.xc"

#define UXMD_CODE_PEN 9 // grey pen stands in for a monospace/code span

class UXMarkdown
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

    static AttributedString* parse(u8* md)
        {
        i32 n = UXMarkdown.slen(md);
        u8* text = new u8[(u32)(n + (i32)1)];  // output text (never longer than the source)
        u8* flags = new u8[(u32)(n + (i32)1)]; // per-output-char: bit0 bold, bit1 italic, bit2 code
        i32 t = (i32)0;
        bool bold = false;
        bool ital = false;
        bool code = false;
        i32 i = (i32)0;
        while (i < n)
            {
            u8 c = md[i];
            // escape: take the next char literally
            if (c == (u8)'\\' && i + (i32)1 < n)
                {
                text[t] = md[i + (i32)1];
                flags[t] = UXMarkdown.flagByte(bold, ital, code);
                t = t + (i32)1;
                i = i + (i32)2;
                continue;
                }
            if (c == (u8)'*' && i + (i32)1 < n && md[i + (i32)1] == (u8)'*')
                {
                bold = !bold;
                i = i + (i32)2;
                continue;
                }
            if (c == (u8)'*')
                {
                ital = !ital;
                i = i + (i32)1;
                continue;
                }
            if (c == (u8)'`')
                {
                code = !code;
                i = i + (i32)1;
                continue;
                }
            text[t] = c;
            flags[t] = UXMarkdown.flagByte(bold, ital, code);
            t = t + (i32)1;
            i = i + (i32)1;
            }
        text[t] = (u8)0;

        AttributedString* as = AttributedString.withString(String.withCString(text));
        // one setAttribute per span of equal flags, not per character
        i32 k = (i32)0;
        while (k < t)
            {
            u8 f = flags[k];
            i32 e = k + (i32)1;
            while (e < t && flags[e] == f)
                {
                e = e + (i32)1;
                }
            if ((f & (u8)1) != (u8)0)
                {
                UXTextStyle.setBold(as, true, k, e - k);
                }
            if ((f & (u8)2) != (u8)0)
                {
                UXTextStyle.setItalic(as, true, k, e - k);
                }
            if ((f & (u8)4) != (u8)0)
                {
                UXTextStyle.setPen(as, (i32)UXMD_CODE_PEN, k, e - k);
                }
            k = e;
            }
        return as;
        }
    static u8 flagByte(bool bold, bool ital, bool code)
        {
        u8 f = (u8)0;
        if (bold)
            {
            f = f | (u8)1;
            }
        if (ital)
            {
            f = f | (u8)2;
            }
        if (code)
            {
            f = f | (u8)4;
            }
        return f;
        }
    }
