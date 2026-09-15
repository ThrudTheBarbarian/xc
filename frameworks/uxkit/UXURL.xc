// UXURL.xc — parse and hold a URL (NSURL / NSURLComponents in shape).
//
// Splits "scheme://host:port/path?query#fragment" into its parts and rebuilds them.  Pure string work,
// so it is fully testable; it is the model half of the networking item (an NSURLConnection would take
// one of these), and it also backs "public.file-url" pasteboard payloads and the file panel.
#import "Array.xc"

class UXURL
    {
    u8* scheme;
    u8* host;
    i32 port; // -1 = unspecified (use the scheme default)
    u8* path;
    u8* query;
    u8* fragment;
    void init(void)
        {
        scheme = (u8*)"";
        host = (u8*)"";
        port = (i32)-1;
        path = (u8*)"";
        query = (u8*)"";
        fragment = (u8*)"";
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
    // first index of char c at/after `from`, or `end` if absent
    static i32 indexOf(u8* s, u8 c, i32 from, i32 end)
        {
        for (i32 i = from; i < end; i = i + (i32)1)
            {
            if (s[i] == c)
                {
                return i;
                }
            }
        return end;
        }
    static i32 toInt(u8* s, i32 start, i32 end)
        {
        i32 v = (i32)0;
        for (i32 i = start; i < end; i = i + (i32)1)
            {
            if (s[i] >= (u8)'0' && s[i] <= (u8)'9')
                {
                v = v * (i32)10 + (i32)(s[i] - (u8)'0');
                }
            }
        return v;
        }

    static UXURL* parse(u8* s)
        {
        UXURL* u = new UXURL();
        i32 n = UXURL.slen(s);
        i32 i = (i32)0;

        // scheme://  — a "://" marks a scheme + authority; otherwise there is no scheme/host
        i32 sep = (i32)-1;
        for (i32 k = (i32)0; k + (i32)2 < n; k = k + (i32)1)
            {
            if (s[k] == (u8)':' && s[k + (i32)1] == (u8)'/' && s[k + (i32)2] == (u8)'/')
                {
                sep = k;
                break;
                }
            }
        if (sep >= (i32)0)
            {
            u.scheme = UXURL.dup(s, (i32)0, sep);
            i = sep + (i32)3;
            // authority runs to the next '/', '?' or '#'
            i32 authEnd = UXURL.indexOf(s, (u8)'/', i, n);
            i32 q = UXURL.indexOf(s, (u8)'?', i, authEnd);
            i32 h = UXURL.indexOf(s, (u8)'#', i, authEnd);
            if (q < authEnd)
                {
                authEnd = q;
                }
            if (h < authEnd)
                {
                authEnd = h;
                }
            i32 colon = UXURL.indexOf(s, (u8)':', i, authEnd);
            if (colon < authEnd)
                {
                u.host = UXURL.dup(s, i, colon - i);
                u.port = UXURL.toInt(s, colon + (i32)1, authEnd);
                }
            else
                {
                u.host = UXURL.dup(s, i, authEnd - i);
                }
            i = authEnd;
            }

        // path runs to '?' or '#'
        i32 pathEnd = UXURL.indexOf(s, (u8)'?', i, n);
        i32 hs = UXURL.indexOf(s, (u8)'#', i, n);
        if (hs < pathEnd)
            {
            pathEnd = hs;
            }
        u.path = UXURL.dup(s, i, pathEnd - i);
        i = pathEnd;

        // ?query
        if (i < n && s[i] == (u8)'?')
            {
            i32 qEnd = UXURL.indexOf(s, (u8)'#', i + (i32)1, n);
            u.query = UXURL.dup(s, i + (i32)1, qEnd - i - (i32)1);
            i = qEnd;
            }
        // #fragment
        if (i < n && s[i] == (u8)'#')
            {
            u.fragment = UXURL.dup(s, i + (i32)1, n - i - (i32)1);
            }
        return u;
        }

    static UXURL* fileURL(u8* path)
        {
        UXURL* u = new UXURL();
        u.scheme = (u8*)"file";
        u.host = (u8*)"";
        u.path = path;
        return u;
        }
    bool isFileURL(void)
        {
        return UXURL.streq(scheme, (u8*)"file");
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

    // Last path segment (the filename), or "".
    u8* lastPathComponent(void)
        {
        i32 n = UXURL.slen(path);
        i32 last = (i32)-1;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            if (path[i] == (u8)'/')
                {
                last = i;
                }
            }
        return UXURL.dup(path, last + (i32)1, n - last - (i32)1);
        }

    u8* toString(void)
        {
        i32 cap = UXURL.slen(scheme) + UXURL.slen(host) + UXURL.slen(path) + UXURL.slen(query) + UXURL.slen(fragment) + (i32)32;
        u8* o = new u8[(u32)cap];
        i32 p = (i32)0;
        p = self.append(o, p, scheme);
        if (UXURL.slen(scheme) > (i32)0)
            {
            p = self.append(o, p, (u8*)"://");
            }
        p = self.append(o, p, host);
        if (port >= (i32)0)
            {
            o[p] = (u8)':';
            p = p + (i32)1;
            p = self.appendNum(o, p, port);
            }
        p = self.append(o, p, path);
        if (UXURL.slen(query) > (i32)0)
            {
            o[p] = (u8)'?';
            p = p + (i32)1;
            p = self.append(o, p, query);
            }
        if (UXURL.slen(fragment) > (i32)0)
            {
            o[p] = (u8)'#';
            p = p + (i32)1;
            p = self.append(o, p, fragment);
            }
        o[p] = (u8)0;
        return o;
        }
    i32 append(u8* o, i32 p, u8* s)
        {
        i32 i = (i32)0;
        while (s[i] != (u8)0)
            {
            o[p] = s[i];
            p = p + (i32)1;
            i = i + (i32)1;
            }
        return p;
        }
    i32 appendNum(u8* o, i32 p, i32 v)
        {
        u8 tmp[12];
        i32 t = (i32)0;
        i32 x = v;
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
            o[p] = tmp[t - (i32)1 - i];
            p = p + (i32)1;
            }
        return p;
        }
    }
