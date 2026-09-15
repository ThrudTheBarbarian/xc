// UXJSON.xc — a small JSON parser + serializer (NSJSONSerialization in shape).
//
// Parses text into a value tree (object / array / string / number / bool / null) and serialises it
// back.  Recursive-descent parse, two-pass serialise (measure then fill), integer numbers.  The base
// for reading/writing settings (pairs with UXKeyValueStore), config, and simple data interchange.
#import "Array.xc"

#define JV_NULL 0
#define JV_BOOL 1
#define JV_NUM 2
#define JV_STR 3
#define JV_ARR 4
#define JV_OBJ 5

class UXJSONValue : Object
    {
    i32 type;
    u8* key; // set when this value is a member of an object
    bool b;
    i32 num;
    u8* str;
    Array<UXJSONValue>* items; // children: array elements, or object members (each with key set)
    void init(void)
        {
        type = (i32)JV_NULL;
        key = (u8*)0;
        b = false;
        num = (i32)0;
        str = (u8*)"";
        items = new Array();
        }

    i32 valueType(void)
        {
        return type;
        }
    i32 asInt(void)
        {
        return num;
        }
    bool asBool(void)
        {
        return b;
        }
    u8* asString(void)
        {
        return str;
        }
    i32 count(void)
        {
        return (i32)items.count();
        }
    UXJSONValue* at(i32 i)
        { return (UXJSONValue* ?)items.get((u16)i);
        }
    UXJSONValue* get(u8* k)
        {
        for (u16 i = (u16)0; i < items.count(); i = i + (u16)1)
            {
            UXJSONValue* m = (UXJSONValue* ?)items.get(i);
            if (m.key != (u8*)0 && UXJSON.streq(m.key, k))
                {
                return m;
                }
            }
        return (UXJSONValue*)0;
        }
    bool has(u8* k)
        {
        return self.get(k) != (UXJSONValue*)0;
        }
    }

    class UXJSON
    {
    u8* src;
    i32 pp;
    i32 plen;
    bool ok;

    void init(void)
        {
        src = (u8*)"";
        pp = (i32)0;
        plen = (i32)0;
        ok = true;
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

    static UXJSONValue* parse(u8* s)
        {
        UXJSON* p = new UXJSON();
        p.src = s;
        p.plen = UXJSON.slen(s);
        p.pp = (i32)0;
        p.ok = true;
        UXJSONValue* v = p.parseValue();
        return p.ok ? v : (UXJSONValue*)0;
        }

    void skipWs(void)
        {
        while (pp < plen && (src[pp] == (u8)' ' || src[pp] == (u8)9 || src[pp] == (u8)10 || src[pp] == (u8)13))
            {
            pp = pp + (i32)1;
            }
        }
    i32 peek(void)
        {
        self.skipWs();
        return pp < plen ? (i32)src[pp] : (i32)-1;
        }

    UXJSONValue* parseValue(void)
        {
        i32 c = self.peek();
        if (c == (i32)'{')
            {
            return self.parseObject();
            }
        if (c == (i32)'[')
            {
            return self.parseArray();
            }
        if (c == (i32)'"')
            {
            UXJSONValue* v = new UXJSONValue();
            v.type = (i32)JV_STR;
            v.str = self.parseString();
            return v;
            }
        if (c == (i32)'t' || c == (i32)'f')
            {
            return self.parseBool();
            }
        if (c == (i32)'n')
            {
            self.expectWord((u8*)"null");
            UXJSONValue* v = new UXJSONValue();
            v.type = (i32)JV_NULL;
            return v;
            }
        if (c == (i32)'-' || (c >= (i32)'0' && c <= (i32)'9'))
            {
            return self.parseNumber();
            }
        ok = false;
        return new UXJSONValue();
        }

    UXJSONValue* parseObject(void)
        {
        UXJSONValue* obj = new UXJSONValue();
        obj.type = (i32)JV_OBJ;
        pp = pp + (i32)1; // '{'
        if (self.peek() == (i32)'}')
            {
            pp = pp + (i32)1;
            return obj;
            }
        while (true)
            {
            if (self.peek() != (i32)'"')
                {
                ok = false;
                return obj;
                }
            u8* k = self.parseString();
            if (self.peek() != (i32)':')
                {
                ok = false;
                return obj;
                }
            pp = pp + (i32)1; // ':'
            UXJSONValue* v = self.parseValue();
            v.key = k;
            obj.items.add(v);
            i32 c = self.peek();
            if (c == (i32)',')
                {
                pp = pp + (i32)1;
                continue;
                }
            if (c == (i32)'}')
                {
                pp = pp + (i32)1;
                break;
                }
            ok = false;
            return obj;
            }
        return obj;
        }

    UXJSONValue* parseArray(void)
        {
        UXJSONValue* arr = new UXJSONValue();
        arr.type = (i32)JV_ARR;
        pp = pp + (i32)1; // '['
        if (self.peek() == (i32)']')
            {
            pp = pp + (i32)1;
            return arr;
            }
        while (true)
            {
            arr.items.add(self.parseValue());
            i32 c = self.peek();
            if (c == (i32)',')
                {
                pp = pp + (i32)1;
                continue;
                }
            if (c == (i32)']')
                {
                pp = pp + (i32)1;
                break;
                }
            ok = false;
            return arr;
            }
        return arr;
        }

    u8* parseString(void)
        {
        pp = pp + (i32)1; // opening '"'
        i32 start = pp;
        // first pass: find the end + whether escapes are present
        bool esc = false;
        while (pp < plen && src[pp] != (u8)'"')
            {
            if (src[pp] == (u8)'\\')
                {
                esc = true;
                pp = pp + (i32)2;
                }
            else
                {
                pp = pp + (i32)1;
                }
            }
        i32 end = pp;
        // closing '"'
        if (pp < plen)
            {
            pp = pp + (i32)1;
            }
        if (!esc)
            {
            return UXJSON.dup(src, start, end - start);
            }
        // second pass: unescape into a fresh buffer
        u8* o = new u8[(u32)(end - start + (i32)1)];
        i32 w = (i32)0;
        i32 i = start;
        while (i < end)
            {
            if (src[i] == (u8)'\\' && i + (i32)1 < end)
                {
                u8 e = src[i + (i32)1];
                if (e == (u8)'n')
                    {
                    o[w] = (u8)10;
                    }
                else if (e == (u8)'t')
                    {
                    o[w] = (u8)9;
                    }
                else if (e == (u8)'r')
                    {
                    o[w] = (u8)13;
                    }
                else if (e == (u8)'b')
                    {
                    o[w] = (u8)8;
                    }
                else if (e == (u8)'f')
                    {
                    o[w] = (u8)12;
                    }
                else
                    {
                    o[w] = e;
                    }
                w = w + (i32)1;
                i = i + (i32)2;
                }
            else
                {
                o[w] = src[i];
                w = w + (i32)1;
                i = i + (i32)1;
                }
            }
        o[w] = (u8)0;
        return o;
        }

    UXJSONValue* parseNumber(void)
        {
        UXJSONValue* v = new UXJSONValue();
        v.type = (i32)JV_NUM;
        i32 sign = (i32)1;
        if (src[pp] == (u8)'-')
            {
            sign = (i32)-1;
            pp = pp + (i32)1;
            }
        i32 x = (i32)0;
        while (pp < plen && src[pp] >= (u8)'0' && src[pp] <= (u8)'9')
            {
            x = x * (i32)10 + (i32)(src[pp] - (u8)'0');
            pp = pp + (i32)1;
            }
        // skip a fractional part (integer model)
        if (pp < plen && src[pp] == (u8)'.')
            {
            pp = pp + (i32)1;
            while (pp < plen && src[pp] >= (u8)'0' && src[pp] <= (u8)'9')
                {
                pp = pp + (i32)1;
                }
            }
        v.num = x * sign;
        return v;
        }
    UXJSONValue* parseBool(void)
        {
        UXJSONValue* v = new UXJSONValue();
        v.type = (i32)JV_BOOL;
        if (src[pp] == (u8)'t')
            {
            self.expectWord((u8*)"true");
            v.b = true;
            }
        else
            {
            self.expectWord((u8*)"false");
            v.b = false;
            }
        return v;
        }
    void expectWord(u8* w)
        {
        i32 i = (i32)0;
        while (w[i] != (u8)0)
            {
            if (pp >= plen || src[pp] != w[i])
                {
                ok = false;
                return;
                }
            pp = pp + (i32)1;
            i = i + (i32)1;
            }
        }

    // ---- serialise (two-pass: measure, then fill) ----------------------------
    static u8* serialize(UXJSONValue* v)
        {
        i32 n = UXJSON.measure(v);
        u8* o = new u8[(u32)(n + (i32)1)];
        i32 e = UXJSON.fill(v, o, (i32)0);
        o[e] = (u8)0;
        return o;
        }
    static i32 numLen(i32 v)
        {
        i32 n = v < (i32)0 ? (i32)1 : (i32)0;
        i32 x = v < (i32)0 ? -v : v;
        if (x == (i32)0)
            {
            return n + (i32)1;
            }
        while (x > (i32)0)
            {
            n = n + (i32)1;
            x = x / (i32)10;
            }
        return n;
        }

    // A byte that must not appear raw inside a JSON string gets a two-character
    // escape.  Only the five the PARSER understands are emitted, so serialize ->
    // parse is exact: emitting \u00XX for the remaining control characters would
    // produce text this reader turns back into the letter 'u'.
    static bool isEscaped(u8 c)
        {
        return c == (u8)'"' || c == (u8)'\\' || c == (u8)10 || c == (u8)9 || c == (u8)13 || c == (u8)8 || c == (u8)12;
        }
    // Serialised length of a string's CONTENTS (no surrounding quotes).
    static i32 escLen(u8* s)
        {
        i32 n = (i32)0;
        i32 i = (i32)0;
        while (s[i] != (u8)0)
            {
            n = n + (UXJSON.isEscaped(s[i]) ? (i32)2 : (i32)1);
            i = i + (i32)1;
            }
        return n;
        }
    // Emit a string's contents with escapes.  Must stay in step with escLen: the
    // buffer was sized by measure(), so an escape it did not count overruns it.
    static i32 putEsc(u8* o, i32 p, u8* s)
        {
        i32 i = (i32)0;
        while (s[i] != (u8)0)
            {
            u8 c = s[i];
            if (UXJSON.isEscaped(c))
                {
                o[p] = (u8)'\\';
                p = p + (i32)1;
                if (c == (u8)10)
                    {
                    o[p] = (u8)'n';
                    }
                else if (c == (u8)9)
                    {
                    o[p] = (u8)'t';
                    }
                else if (c == (u8)13)
                    {
                    o[p] = (u8)'r';
                    }
                else if (c == (u8)8)
                    {
                    o[p] = (u8)'b';
                    }
                else if (c == (u8)12)
                    {
                    o[p] = (u8)'f';
                    }
                // " and \ stand for themselves
                else
                    {
                    o[p] = c;
                    }
                }
            else
                {
                o[p] = c;
                }
            p = p + (i32)1;
            i = i + (i32)1;
            }
        return p;
        }
    static i32 measure(UXJSONValue* v)
        {
        // null
        if (v == (UXJSONValue*)0 || v.type == (i32)JV_NULL)
            {
            return (i32)4;
            }
        // true/false
        if (v.type == (i32)JV_BOOL)
            {
            return v.b ? (i32)4 : (i32)5;
            }
        if (v.type == (i32)JV_NUM)
            {
            return UXJSON.numLen(v.num);
            }
        // quotes + escapes
        if (v.type == (i32)JV_STR)
            {
            return UXJSON.escLen(v.str) + (i32)2;
            }
        i32 total = (i32)2; // brackets/braces
        i32 n = (i32)v.items.count();
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            UXJSONValue* m = (UXJSONValue* ?)v.items.get((u16)i);
            // "key":
            if (v.type == (i32)JV_OBJ)
                {
                total = total + UXJSON.escLen(m.key) + (i32)3;
                }
            total = total + UXJSON.measure(m);
            // comma
            if (i < n - (i32)1)
                {
                total = total + (i32)1;
                }
            }
        return total;
        }
    static i32 fill(UXJSONValue* v, u8* o, i32 p)
        {
        if (v == (UXJSONValue*)0 || v.type == (i32)JV_NULL)
            {
            return UXJSON.puts(o, p, (u8*)"null");
            }
        if (v.type == (i32)JV_BOOL)
            {
            return UXJSON.puts(o, p, v.b ? (u8*)"true" : (u8*)"false");
            }
        if (v.type == (i32)JV_NUM)
            {
            return UXJSON.putNum(o, p, v.num);
            }
        if (v.type == (i32)JV_STR)
            {
            o[p] = (u8)'"';
            p = p + (i32)1;
            p = UXJSON.putEsc(o, p, v.str);
            o[p] = (u8)'"';
            return p + (i32)1;
            }
        bool obj = v.type == (i32)JV_OBJ;
        o[p] = obj ? (u8)'{' : (u8)'[';
        p = p + (i32)1;
        i32 n = (i32)v.items.count();
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            UXJSONValue* m = (UXJSONValue* ?)v.items.get((u16)i);
            if (obj)
                {
                o[p] = (u8)'"';
                p = p + (i32)1;
                p = UXJSON.putEsc(o, p, m.key);
                o[p] = (u8)'"';
                p = p + (i32)1;
                o[p] = (u8)':';
                p = p + (i32)1;
                }
            p = UXJSON.fill(m, o, p);
            if (i < n - (i32)1)
                {
                o[p] = (u8)',';
                p = p + (i32)1;
                }
            }
        o[p] = obj ? (u8)'}' : (u8)']';
        return p + (i32)1;
        }
    static i32 puts(u8* o, i32 p, u8* s)
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
    static i32 putNum(u8* o, i32 p, i32 v)
        {
        if (v < (i32)0)
            {
            o[p] = (u8)'-';
            p = p + (i32)1;
            v = -v;
            }
        u8 tmp[12];
        i32 t = (i32)0;
        if (v == (i32)0)
            {
            tmp[0] = (u8)'0';
            t = (i32)1;
            }
        while (v > (i32)0)
            {
            tmp[t] = (u8)((i32)'0' + v % (i32)10);
            v = v / (i32)10;
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
