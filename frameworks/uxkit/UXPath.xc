// UXPath.xc — a slash-separated path value (NSString path methods / NSURL path in shape).
//
// Splits "/a/b/c.txt" into components, rebuilds them, and does the everyday path surgery: last
// component, extension, appending, deleting the last component, and NORMALIZING (resolving "." and
// ".." without touching a filesystem).  Pure string work, so it is fully unit-testable, and it feeds
// the breadcrumb (a path bar is a normalized path's components) and file navigation.
#import "Array.xc"

class UXPathComp : Object
    {
    u8* s;
    void init(void)
        {
        s = (u8*)"";
        }
    }

    class UXPath
    {
    Array<UXPathComp>* comps; // of UXPathComp, in order
    bool absolute;            // began with '/'
    void init(void)
        {
        comps = new Array();
        absolute = false;
        }

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
    // copy s[start .. start+len) into a fresh NUL-terminated buffer
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
    static u8* dupWhole(u8* s)
        {
        return UXPath.dup(s, (i32)0, UXPath.slen(s));
        }

    void addComp(u8* s)
        {
        UXPathComp* c = new UXPathComp();
        c.s = s;
        comps.add(c);
        }

    static UXPath* parse(u8* s)
        {
        UXPath* p = new UXPath();
        i32 n = UXPath.slen(s);
        i32 i = (i32)0;
        if (n > (i32)0 && s[0] == (u8)'/')
            {
            p.absolute = true;
            i = (i32)1;
            }
        i32 start = i;
        while (i <= n)
            {
            if (i == n || s[i] == (u8)'/')
                {
                if (i > start)
                    {
                    p.addComp(UXPath.dup(s, start, i - start));
                    }
                start = i + (i32)1;
                }
            i = i + (i32)1;
            }
        return p;
        }

    i32 count(void)
        {
        return (i32)comps.count();
        }
    u8* component(i32 i)
        { return ((UXPathComp* ?)comps.get((u16)i)).s;
        }
    u8* lastComponent(void)
        {
        return self.count() > (i32)0 ? self.component(self.count() - (i32)1) : (u8*)"";
        }
    bool isAbsolute(void)
        {
        return absolute;
        }

    u8* toString(void)
        {
        i32 n = self.count();
        if (n == (i32)0)
            {
            return absolute ? (u8*)"/" : (u8*)"";
            }
        i32 total = absolute ? (i32)1 : (i32)0;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            total = total + UXPath.slen(self.component(i));
            }
        total = total + (n - (i32)1); // separators
        u8* out = new u8[(u32)(total + (i32)1)];
        i32 o = (i32)0;
        if (absolute)
            {
            out[o] = (u8)'/';
            o = o + (i32)1;
            }
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            if (i > (i32)0)
                {
                out[o] = (u8)'/';
                o = o + (i32)1;
                }
            u8* c = self.component(i);
            i32 cl = UXPath.slen(c);
            for (i32 k = (i32)0; k < cl; k = k + (i32)1)
                {
                out[o] = c[k];
                o = o + (i32)1;
                }
            }
        out[o] = (u8)0;
        return out;
        }

    UXPath* copy(void)
        {
        UXPath* p = new UXPath();
        p.absolute = absolute;
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            p.addComp(self.component(i));
            }
        return p;
        }
    UXPath* appendingComponent(u8* c)
        {
        UXPath* p = self.copy();
        p.addComp(UXPath.dupWhole(c));
        return p;
        }
    UXPath* deletingLastComponent(void)
        {
        UXPath* p = self.copy();
        if (p.comps.count() > (u16)0)
            {
            p.comps.removeLast();
            }
        return p;
        }

    // extension of the last component (after the final '.'), or "" — leading-dot names have none.
    u8* pathExtension(void)
        {
        u8* last = self.lastComponent();
        i32 n = UXPath.slen(last);
        i32 dot = (i32)-1;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            if (last[i] == (u8)'.')
                {
                dot = i;
                }
            }
        if (dot <= (i32)0 || dot == n - (i32)1)
            {
            return (u8*)"";
            }
        return UXPath.dup(last, dot + (i32)1, n - dot - (i32)1);
        }
    u8* lastComponentWithoutExtension(void)
        {
        u8* last = self.lastComponent();
        i32 n = UXPath.slen(last);
        i32 dot = (i32)-1;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            if (last[i] == (u8)'.')
                {
                dot = i;
                }
            }
        if (dot <= (i32)0)
            {
            return UXPath.dupWhole(last);
            }
        return UXPath.dup(last, (i32)0, dot);
        }

    // Resolve "." (drop) and ".." (pop the previous real component) without hitting a filesystem.
    UXPath* normalized(void)
        {
        UXPath* p = new UXPath();
        p.absolute = absolute;
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            u8* c = self.component(i);
            if (UXPath.streq(c, (u8*)"."))
                {
                continue;
                }
            if (UXPath.streq(c, (u8*)".."))
                {
                i32 m = (i32)p.comps.count();
                if (m > (i32)0 && !UXPath.streq(p.component(m - (i32)1), (u8*)".."))
                    {
                    p.comps.removeLast(); // pop the parent
                    }
                else if (!absolute)
                    {
                    p.addComp(UXPath.dupWhole((u8*)"..")); // keep a leading .. in a relative path
                    }
                continue;
                }
            p.addComp(UXPath.dupWhole(c));
            }
        return p;
        }
    }
