// UXString.xc — the small amount of string work a UI toolkit cannot avoid.
//
// Building a label, a status line or an alert means concatenating and formatting, and
// xtc's Stdio has no snprintf.  Every app would otherwise write this, so it lives here.
#import "UXLibc.xc"

class UXStr
    {
    static u16 len(u8* s)
        {
        u16 n = (u16)0;
        while (s[n] != (u8)0)
            {
            n = n + (u16)1;
            }
        return n;
        }

    // a + sep + b   (sep = 0 for none; skipped if `a` is empty).  Fresh buffer.
    static u8* cat(u8* a, u8 sep, u8* b)
        {
        u16 la = UXStr.len(a);
        u16 lb = UXStr.len(b);
        u16 extra = (sep != (u8)0 && la > (u16)0) ? (u16)1 : (u16)0;
        u8* o = (u8*)malloc((u32)(la + extra + lb + (u16)1));
        u16 k = (u16)0;
        for (u16 i = (u16)0; i < la; i++)
            {
            o[k] = a[i];
            k = k + (u16)1;
            }
        if (extra != (u16)0)
            {
            o[k] = sep;
            k = k + (u16)1;
            }
        for (u16 i = (u16)0; i < lb; i++)
            {
            o[k] = b[i];
            k = k + (u16)1;
            }
        o[k] = (u8)0;
        return o;
        }

    static u8* append(u8* a, u8* b)
        {
        return UXStr.cat(a, (u8)0, b);
        }

    // A private copy — for a string that came out of a shared scratch buffer and must outlive the
    // next call that fills it (UXKeyValueStore reading the settings store).
    static u8* dup(u8* s)
        {
        return UXStr.cat(s, (u8)0, (u8*)"");
        }

    // The inverse of fromInt: leading blanks and one sign, then digits, stopping at the first thing
    // that is not one.  Not a validator — a settings value that is not a number reads as 0.
    static i32 toInt(u8* s)
        {
        if (s == (u8*)0)
            {
            return (i32)0;
            }
        i32 i = (i32)0;
        while (s[i] == (u8)32 || s[i] == (u8)9)
            {
            i = i + (i32)1;
            }
        bool neg = false;
        if (s[i] == (u8)45)
            {
            neg = true;
            i = i + (i32)1;
            }
        else if (s[i] == (u8)43)
            {
            i = i + (i32)1;
            }
        i32 v = (i32)0;
        while (s[i] >= (u8)48 && s[i] <= (u8)57)
            {
            v = v * (i32)10 + (i32)(s[i] - (u8)48);
            i = i + (i32)1;
            }
        return neg ? -v : v;
        }

    static u8* fromInt(i32 v)
        {
        u8* o = (u8*)malloc((u32)14);
        u16 k = (u16)0;
        bool neg = v < (i32)0;
        u32 n = neg ? (u32)(-v) : (u32)v;
        u8 d[12];
        u16 nd = (u16)0;
        if (n == (u32)0)
            {
            d[0] = (u8)48;
            nd = (u16)1;
            }
        while (n > (u32)0)
            {
            d[nd] = (u8)(48 + (n % (u32)10));
            n = n / (u32)10;
            nd = nd + (u16)1;
            }
        if (neg)
            {
            o[k] = (u8)45;
            k = k + (u16)1;
            }
        while (nd > (u16)0)
            {
            nd = nd - (u16)1;
            o[k] = d[nd];
            k = k + (u16)1;
            }
        o[k] = (u8)0;
        return o;
        }

    static u8* fromHex(u32 v)
        {
        u8* o = (u8*)malloc((u32)12);
        u8 hx[16];
        for (u16 i = (u16)0; i < (u16)10; i++)
            {
            hx[i] = (u8)(48 + i);
            }
        // 'a'..'f'
        for (u16 i = (u16)10; i < (u16)16; i++)
            {
            hx[i] = (u8)(87 + i);
            }
        u16 k = (u16)0;
        bool started = false;
        for (i32 sh = (i32)28; sh >= (i32)0; sh = sh - (i32)4)
            {
            u8 nib = (u8)((v >> (u32)sh) & (u32)15);
            if (nib != (u8)0)
                {
                started = true;
                }
            if (started)
                {
                o[k] = hx[nib];
                k = k + (u16)1;
                }
            }
        if (k == (u16)0)
            {
            o[k] = (u8)48;
            k = k + (u16)1;
            }
        o[k] = (u8)0;
        return o;
        }
    }
