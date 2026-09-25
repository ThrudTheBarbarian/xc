// Json.xc — just enough JSON for the App Store Connect API: parse a response
// into a tree, walk it by key and index, and quote a string for a request.

#import "Foundation.xc"

#define JS_NULL $0
#define JS_BOOL $1
#define JS_NUMBER $2
#define JS_STRING $3
#define JS_ARRAY $4
#define JS_OBJECT $5

class JsonValue
    {
    u32 _kind;
    String* _text;  // string contents, or a number's literal
    bool _bool;
    Array* _keys;   // object: String*
    Array* _values; // object values / array elements: JsonValue*
    void init(void)
        {
        _kind = (u32)JS_NULL;
        _keys = new Array();
        _values = new Array();
        }
    u32 kind(void)
        {
        return _kind;
        }
    // The member `key` of an object, or null.
    JsonValue* get(string key)
        {
        if (_kind != (u32)JS_OBJECT)
            return (JsonValue*)0;
        String* k = String.withCString(key);
        for (u32 i = (u32)0; i < _keys.count(); i = i + (u32)1)
            if (((String*)_keys.get(i)).equals(k))
                return (JsonValue*)_values.get(i);
        return (JsonValue*)0;
        }
    u32 count(void)
        {
        return _kind == (u32)JS_ARRAY ? _values.count() : (u32)0;
        }
    JsonValue* at(u32 i)
        {
        return (JsonValue*)_values.get(i);
        }
    // A string member's text, or null when it is absent or not a string.
    String* str(void)
        {
        return _kind == (u32)JS_STRING ? _text : (String*)0;
        }
    // Walk a chain of object keys; null if any link is missing.
    static String* path2(JsonValue* v, string a, string b)
        {
        JsonValue* x = v == (JsonValue*)0 ? (JsonValue*)0 : v.get(a);
        x = x == (JsonValue*)0 ? (JsonValue*)0 : x.get(b);
        return x == (JsonValue*)0 ? (String*)0 : x.str();
        }
    }

class Json
    {
    String* _s;
    u32 _p;
    bool _bad;
    void init(void)
        {
        _p = (u32)0;
        _bad = false;
        }

    // The document in `text`, or null when it does not parse.
    static JsonValue* parse(String* text)
        {
        Json* j = new Json();
        j._s = text;
        JsonValue* v = j.value();
        if (j._bad)
            return (JsonValue*)0;
        return v;
        }

    void ws(void)
        {
        while (_p < _s.byteLength())
            {
            u8 c = _s.byteAt(_p);
            if (c == (u8)32 || c == (u8)9 || c == (u8)10 || c == (u8)13)
                _p = _p + (u32)1;
            else
                break;
            }
        }
    u8 peek(void)
        {
        return _p < _s.byteLength() ? _s.byteAt(_p) : (u8)0;
        }
    bool lit(string w)
        {
        String* l = String.withCString(w);
        if (_p + l.byteLength() > _s.byteLength())
            return false;
        if (!_s.substringBytes(_p, l.byteLength()).equals(l))
            return false;
        _p = _p + l.byteLength();
        return true;
        }
    static u32 hexv(u8 c)
        {
        if (c >= (u8)'0' && c <= (u8)'9')
            return (u32)(c - (u8)'0');
        if (c >= (u8)'a' && c <= (u8)'f')
            return (u32)(c - (u8)'a') + (u32)10;
        if (c >= (u8)'A' && c <= (u8)'F')
            return (u32)(c - (u8)'A') + (u32)10;
        return (u32)0;
        }
    String* readString(void)
        {
        String* out = String.withCString("");
        _p = _p + (u32)1; // opening quote
        while (_p < _s.byteLength())
            {
            u8 c = _s.byteAt(_p);
            _p = _p + (u32)1;
            if (c == (u8)'"')
                return out;
            if (c != (u8)92)
                {
                out.appendByte(c);
                continue;
                }
            if (_p >= _s.byteLength())
                break;
            u8 e = _s.byteAt(_p);
            _p = _p + (u32)1;
            if (e == (u8)'n')
                out.appendByte((u8)10);
            else if (e == (u8)'t')
                out.appendByte((u8)9);
            else if (e == (u8)'r')
                out.appendByte((u8)13);
            else if (e == (u8)'b')
                out.appendByte((u8)8);
            else if (e == (u8)'f')
                out.appendByte((u8)12);
            else if (e == (u8)'u' && _p + (u32)4 <= _s.byteLength())
                {
                u32 cp = (u32)0;
                for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                    cp = cp * (u32)16 + Json.hexv(_s.byteAt(_p + k));
                _p = _p + (u32)4;
                // A surrogate pair is two escapes.
                if (cp >= (u32)$D800 && cp < (u32)$DC00 && _p + (u32)6 <= _s.byteLength()
                    && _s.byteAt(_p) == (u8)92 && _s.byteAt(_p + (u32)1) == (u8)'u')
                    {
                    u32 lo = (u32)0;
                    for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                        lo = lo * (u32)16 + Json.hexv(_s.byteAt(_p + (u32)2 + k));
                    _p = _p + (u32)6;
                    cp = (u32)$10000 + ((cp - (u32)$D800) << (u32)10) + (lo - (u32)$DC00);
                    }
                out.appendChar(cp);
                }
            else
                out.appendByte(e); // \" \\ \/
            }
        _bad = true;
        return out;
        }
    JsonValue* value(void)
        {
        ws();
        JsonValue* v = new JsonValue();
        u8 c = peek();
        if (c == (u8)'{')
            {
            v._kind = (u32)JS_OBJECT;
            _p = _p + (u32)1;
            ws();
            if (peek() == (u8)'}')
                {
                _p = _p + (u32)1;
                return v;
                }
            while (!_bad)
                {
                ws();
                if (peek() != (u8)'"')
                    {
                    _bad = true;
                    break;
                    }
                String* k = readString();
                ws();
                if (peek() != (u8)':')
                    {
                    _bad = true;
                    break;
                    }
                _p = _p + (u32)1;
                JsonValue* m = value();
                v._keys.add((Object*)k);
                v._values.add((Object*)m);
                ws();
                if (peek() == (u8)',')
                    {
                    _p = _p + (u32)1;
                    continue;
                    }
                if (peek() == (u8)'}')
                    {
                    _p = _p + (u32)1;
                    break;
                    }
                _bad = true;
                }
            return v;
            }
        if (c == (u8)'[')
            {
            v._kind = (u32)JS_ARRAY;
            _p = _p + (u32)1;
            ws();
            if (peek() == (u8)']')
                {
                _p = _p + (u32)1;
                return v;
                }
            while (!_bad)
                {
                v._values.add((Object*)value());
                ws();
                if (peek() == (u8)',')
                    {
                    _p = _p + (u32)1;
                    continue;
                    }
                if (peek() == (u8)']')
                    {
                    _p = _p + (u32)1;
                    break;
                    }
                _bad = true;
                }
            return v;
            }
        if (c == (u8)'"')
            {
            v._kind = (u32)JS_STRING;
            v._text = readString();
            return v;
            }
        if (lit("true"))
            {
            v._kind = (u32)JS_BOOL;
            v._bool = true;
            return v;
            }
        if (lit("false"))
            {
            v._kind = (u32)JS_BOOL;
            return v;
            }
        if (lit("null"))
            return v;
        if (c == (u8)'-' || (c >= (u8)'0' && c <= (u8)'9'))
            {
            v._kind = (u32)JS_NUMBER;
            u32 st = _p;
            while (_p < _s.byteLength())
                {
                u8 d = _s.byteAt(_p);
                if ((d >= (u8)'0' && d <= (u8)'9') || d == (u8)'-' || d == (u8)'+' || d == (u8)'.' || d == (u8)'e' || d == (u8)'E')
                    _p = _p + (u32)1;
                else
                    break;
                }
            v._text = _s.substringBytes(st, _p - st);
            return v;
            }
        _bad = true;
        return v;
        }

    // `s` as a JSON string literal, quotes included.
    static String* quote(String* s)
        {
        String* o = String.withCString("\"");
        String* H = String.withCString("0123456789abcdef");
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)'"')
                o.appendCString("\\\"");
            else if (c == (u8)92)
                o.appendCString("\\\\");
            else if (c == (u8)'/')
                o.appendCString("\\/");
            else if (c == (u8)10)
                o.appendCString("\\n");
            else if (c == (u8)13)
                o.appendCString("\\r");
            else if (c == (u8)9)
                o.appendCString("\\t");
            else if (c < (u8)32)
                {
                o.appendCString("\\u00");
                o.appendByte(H.byteAt((u32)(c >> (u8)4)));
                o.appendByte(H.byteAt((u32)(c & (u8)15)));
                }
            else
                o.appendByte(c);
            }
        o.appendCString("\"");
        return o;
        }
    }
