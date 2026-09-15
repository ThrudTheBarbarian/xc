// UXText.xc — everyday string utilities (the NSString convenience methods).
//
// Trim, split, join, case-fold, prefix/suffix/contains, single-character replace — the operations an
// app reaches for constantly and that the base String class leaves out.  Split/trim take an
// UXCharacterSet so a caller controls the delimiters.  Results are freshly-allocated u8* (or an Array
// of string carriers for split); nothing is mutated in place.
#import "Array.xc"
#import "UXCharacterSet.xc"

class UXStrItem : Object
    {
    u8* s;
    void init(void)
        {
        s = (u8*)"";
        }
    }

    class UXText
    {
    static i32 slen(u8* s)
        {
        if (s == (u8*)0)
            {
            return (i32)0;
            }
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }
    static u8* dup(u8* s, i32 start, i32 len)
        {
        if (len < (i32)0)
            {
            len = (i32)0;
            }
        u8* o = new u8[(u32)(len + (i32)1)];
        for (i32 i = (i32)0; i < len; i = i + (i32)1)
            {
            o[i] = s[start + i];
            }
        o[len] = (u8)0;
        return o;
        }
    static u8 lower(u8 c)
        {
        return (c >= (u8)'A' && c <= (u8)'Z') ? (u8)(c + (u8)32) : c;
        }
    static u8 upper(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') ? (u8)(c - (u8)32) : c;
        }

    // ---- trim ----------------------------------------------------------------
    static u8* trim(u8* s, UXCharacterSet* cs)
        {
        i32 n = UXText.slen(s);
        i32 a = (i32)0;
        i32 b = n;
        while (a < b && cs.contains((i32)s[a]))
            {
            a = a + (i32)1;
            }
        while (b > a && cs.contains((i32)s[b - (i32)1]))
            {
            b = b - (i32)1;
            }
        return UXText.dup(s, a, b - a);
        }
    static u8* trimWhitespace(u8* s)
        {
        return UXText.trim(s, UXCharacterSet.whitespaceAndNewlines());
        }

    // ---- split ---------------------------------------------------------------
    static void addPart(Array<UXStrItem>* out, u8* s, i32 start, i32 len)
        {
        UXStrItem* it = new UXStrItem();
        it.s = UXText.dup(s, start, len);
        out.add(it);
        }
    static Array<UXStrItem>* split(u8* s, u8 delim)
        {
        Array<UXStrItem>* out = new Array();
        i32 n = UXText.slen(s);
        i32 start = (i32)0;
        for (i32 i = (i32)0; i <= n; i = i + (i32)1)
            {
            if (i == n || s[i] == delim)
                {
                UXText.addPart(out, s, start, i - start);
                start = i + (i32)1;
                }
            }
        return out;
        }
    // Split on any character in the set, dropping empty fields (tokenizing).
    static Array<UXStrItem>* tokenize(u8* s, UXCharacterSet* sep)
        {
        Array<UXStrItem>* out = new Array();
        i32 n = UXText.slen(s);
        i32 start = (i32)-1;
        for (i32 i = (i32)0; i <= n; i = i + (i32)1)
            {
            bool brk = (i == n) || sep.contains((i32)s[i]);
            if (brk)
                {
                if (start >= (i32)0)
                    {
                    UXText.addPart(out, s, start, i - start);
                    start = (i32)-1;
                    }
                }
            else if (start < (i32)0)
                {
                start = i;
                }
            }
        return out;
        }
    static u8* partAt(Array<UXStrItem>* parts, i32 i)
        { return ((UXStrItem* ?)parts.get((u16)i)).s;
        }

    // ---- join ----------------------------------------------------------------
    static u8* join(Array<UXStrItem>* parts, u8* sep)
        {
        i32 sl = UXText.slen(sep);
        i32 total = (i32)0;
        i32 n = (i32)parts.count();
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            total = total + UXText.slen(UXText.partAt(parts, i));
            if (i < n - (i32)1)
                {
                total = total + sl;
                }
            }
        u8* o = new u8[(u32)(total + (i32)1)];
        i32 p = (i32)0;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            if (i > (i32)0)
                {
                i32 k = (i32)0;
                while (sep[k] != (u8)0)
                    {
                    o[p] = sep[k];
                    p = p + (i32)1;
                    k = k + (i32)1;
                    }
                }
            u8* part = UXText.partAt(parts, i);
            i32 k = (i32)0;
            while (part[k] != (u8)0)
                {
                o[p] = part[k];
                p = p + (i32)1;
                k = k + (i32)1;
                }
            }
        o[p] = (u8)0;
        return o;
        }

    // ---- case ----------------------------------------------------------------
    static u8* toLower(u8* s)
        {
        i32 n = UXText.slen(s);
        u8* o = new u8[(u32)(n + (i32)1)];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            o[i] = UXText.lower(s[i]);
            }
        o[n] = (u8)0;
        return o;
        }
    static u8* toUpper(u8* s)
        {
        i32 n = UXText.slen(s);
        u8* o = new u8[(u32)(n + (i32)1)];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            o[i] = UXText.upper(s[i]);
            }
        o[n] = (u8)0;
        return o;
        }

    // ---- predicates ----------------------------------------------------------
    static bool hasPrefix(u8* s, u8* p)
        {
        i32 i = (i32)0;
        while (p[i] != (u8)0)
            {
            if (s[i] != p[i])
                {
                return false;
                }
            i = i + (i32)1;
            }
        return true;
        }
    static bool hasSuffix(u8* s, u8* suf)
        {
        i32 sn = UXText.slen(s);
        i32 fn = UXText.slen(suf);
        if (fn > sn)
            {
            return false;
            }
        for (i32 i = (i32)0; i < fn; i = i + (i32)1)
            {
            if (s[sn - fn + i] != suf[i])
                {
                return false;
                }
            }
        return true;
        }
    static bool contains(u8* hay, u8* needle)
        {
        i32 hn = UXText.slen(hay);
        i32 nn = UXText.slen(needle);
        if (nn == (i32)0)
            {
            return true;
            }
        for (i32 start = (i32)0; start + nn <= hn; start = start + (i32)1)
            {
            i32 j = (i32)0;
            while (j < nn && hay[start + j] == needle[j])
                {
                j = j + (i32)1;
                }
            if (j == nn)
                {
                return true;
                }
            }
        return false;
        }
    static u8* replaceChar(u8* s, u8 from, u8 to)
        {
        i32 n = UXText.slen(s);
        u8* o = new u8[(u32)(n + (i32)1)];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            o[i] = s[i] == from ? to : s[i];
            }
        o[n] = (u8)0;
        return o;
        }
    }
