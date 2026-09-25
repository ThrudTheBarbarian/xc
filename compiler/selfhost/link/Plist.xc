// Plist.xc — XML property lists, read and written the way CoreFoundation
// writes them, and the entitlements of a provisioning profile.
//
// A .mobileprovision is a CMS SignedData whose content is an XML plist. Its
// `Entitlements` dictionary becomes the XCC ENTITLEMENTS block of an identity
// bundle, re-serialised as its own XML plist: keys sorted, one tab per level,
// the CoreFoundation header. The signer hashes those bytes into the
// CodeDirectory, so they have to be the bytes the macOS serialiser produces.
//
// Bytes are Array@ of Number, as in CodeSign.xc.

#import "Foundation.xc"
#import "CodeSign.xc"

#define PL_DICT $1
#define PL_ARRAY $2
#define PL_STRING $3
#define PL_TRUE $4
#define PL_FALSE $5
#define PL_INTEGER $6
#define PL_REAL $7
#define PL_DATE $8
#define PL_DATA $9

class PlistNode
    {
    u32 _kind;
    String* _text;  // string/integer/real/date: the (unescaped) text
    Array* _bytes;  // data
    Array* _keys;   // dict: String*
    Array* _values; // dict values, or array elements: PlistNode*
    void init(void)
        {
        _kind = (u32)0;
        _keys = new Array();
        _values = new Array();
        }
    u32 kind(void)
        {
        return _kind;
        }
    String* text(void)
        {
        return _text;
        }
    Array* keys(void)
        {
        return _keys;
        }
    Array* values(void)
        {
        return _values;
        }
    // The value under `key` in a dict, or null.
    PlistNode* get(String* key)
        {
        for (u32 i = (u32)0; i < _keys.count(); i = i + (u32)1)
            if (((String*)_keys.get(i)).equals(key))
                return (PlistNode*)_values.get(i);
        return (PlistNode*)0;
        }
    }

class Plist
    {
    String* _s;
    u32 _p;
    bool _bad;
    void init(void)
        {
        _p = (u32)0;
        _bad = false;
        }

    // ── reading ─────────────────────────────────────────────────────────────
    // The root value of an XML plist, or null when it does not parse.
    static PlistNode* parse(Array* bytes)
        {
        String* s = String.withCString("");
        for (u32 i = (u32)0; i < bytes.count(); i = i + (u32)1)
            s.appendByte((u8)Bytes.at(bytes, i));
        Plist* r = new Plist();
        r._s = s;
        u32 at = s.byteIndexOf(String.withCString("<plist"));
        if (at == String.notFound())
            return (PlistNode*)0;
        r._p = at;
        r.skipTag();
        PlistNode* v = r.value();
        if (r._bad)
            return (PlistNode*)0;
        return v;
        }

    bool at(string lit)
        {
        String* l = String.withCString(lit);
        u32 n = l.byteLength();
        if (_p + n > _s.byteLength())
            return false;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            if (_s.byteAt(_p + i) != l.byteAt(i))
                return false;
        return true;
        }
    void skipWs(void)
        {
        while (_p < _s.byteLength())
            {
            u8 c = _s.byteAt(_p);
            if (c == (u8)32 || c == (u8)9 || c == (u8)10 || c == (u8)13)
                _p = _p + (u32)1;
            else if (at("<!--"))
                {
                u32 e = _s.byteIndexOf(String.withCString("-->"), _p);
                _p = e == String.notFound() ? _s.byteLength() : e + (u32)3;
                }
            else
                break;
            }
        }
    // Past the next '>'.
    void skipTag(void)
        {
        while (_p < _s.byteLength() && _s.byteAt(_p) != (u8)'>')
            _p = _p + (u32)1;
        if (_p < _s.byteLength())
            _p = _p + (u32)1;
        }
    // The tag name at _p ('<' already current), without consuming it.
    String* tagName(void)
        {
        u32 i = _p + (u32)1;
        String* n = String.withCString("");
        while (i < _s.byteLength())
            {
            u8 c = _s.byteAt(i);
            if (c == (u8)'>' || c == (u8)'/' || c == (u8)32 || c == (u8)9 || c == (u8)10 || c == (u8)13)
                break;
            n.appendByte(c);
            i = i + (u32)1;
            }
        return n;
        }
    // Is the tag at _p self-closing (`<x/>`)?
    bool selfClosing(void)
        {
        u32 i = _p;
        while (i < _s.byteLength() && _s.byteAt(i) != (u8)'>')
            i = i + (u32)1;
        return i > (u32)0 && i < _s.byteLength() && _s.byteAt(i - (u32)1) == (u8)'/';
        }
    // The raw text up to `</name>`, consumed with the closing tag.
    String* textUntilClose(String* name)
        {
        String* close = String.withCString("</");
        close.append(name);
        close.appendCString(">");
        u32 e = _s.byteIndexOf(close, _p);
        if (e == String.notFound())
            {
            _bad = true;
            return String.withCString("");
            }
        String* raw = _s.substringBytes(_p, e - _p);
        _p = e + close.byteLength();
        return Plist.unescape(raw);
        }
    static String* unescape(String* raw)
        {
        String* out = String.withCString("");
        u32 i = (u32)0;
        u32 n = raw.byteLength();
        while (i < n)
            {
            u8 c = raw.byteAt(i);
            if (c == (u8)'<' && i + (u32)9 <= n && raw.substringBytes(i, (u32)9).equals(String.withCString("<![CDATA[")))
                {
                u32 e = raw.byteIndexOf(String.withCString("]]>"), i + (u32)9);
                if (e == String.notFound())
                    e = n;
                out.append(raw.substringBytes(i + (u32)9, e - i - (u32)9));
                i = e + (u32)3;
                continue;
                }
            if (c != (u8)'&')
                {
                out.appendByte(c);
                i = i + (u32)1;
                continue;
                }
            u32 semi = raw.byteIndexOf(String.withCString(";"), i);
            if (semi == String.notFound())
                {
                out.appendByte(c);
                i = i + (u32)1;
                continue;
                }
            String* ent = raw.substringBytes(i + (u32)1, semi - i - (u32)1);
            if (ent.equals(String.withCString("amp")))
                out.appendByte((u8)'&');
            else if (ent.equals(String.withCString("lt")))
                out.appendByte((u8)'<');
            else if (ent.equals(String.withCString("gt")))
                out.appendByte((u8)'>');
            else if (ent.equals(String.withCString("quot")))
                out.appendByte((u8)'"');
            else if (ent.equals(String.withCString("apos")))
                out.appendByte((u8)39);
            else if (ent.byteLength() > (u32)1 && ent.byteAt((u32)0) == (u8)'#')
                {
                u32 cp = (u32)0;
                bool hex = ent.byteAt((u32)1) == (u8)'x' || ent.byteAt((u32)1) == (u8)'X';
                for (u32 k = hex ? (u32)2 : (u32)1; k < ent.byteLength(); k = k + (u32)1)
                    {
                    u32 d = (u32)ent.byteAt(k);
                    if (d >= (u32)'0' && d <= (u32)'9')
                        d = d - (u32)'0';
                    else if (d >= (u32)'a' && d <= (u32)'f')
                        d = d - (u32)'a' + (u32)10;
                    else if (d >= (u32)'A' && d <= (u32)'F')
                        d = d - (u32)'A' + (u32)10;
                    cp = cp * (hex ? (u32)16 : (u32)10) + d;
                    }
                out.appendChar(cp);
                }
            else
                {
                out.append(raw.substringBytes(i, semi - i + (u32)1));
                }
            i = semi + (u32)1;
            }
        return out;
        }
    PlistNode* value(void)
        {
        skipWs();
        if (_p >= _s.byteLength() || _s.byteAt(_p) != (u8)'<')
            {
            _bad = true;
            return (PlistNode*)0;
            }
        String* name = tagName();
        bool empty = selfClosing();
        skipTag();
        PlistNode* v = new PlistNode();
        if (name.equals(String.withCString("dict")))
            {
            v._kind = (u32)PL_DICT;
            if (empty)
                return v;
            while (!_bad)
                {
                skipWs();
                if (at("</dict"))
                    {
                    skipTag();
                    break;
                    }
                if (!at("<key"))
                    {
                    _bad = true;
                    break;
                    }
                bool emptyKey = selfClosing();
                skipTag();
                String* k = emptyKey ? String.withCString("") : textUntilClose(String.withCString("key"));
                PlistNode* kv = value();
                if (kv == (PlistNode*)0)
                    {
                    _bad = true;
                    break;
                    }
                v._keys.add((Object*)k);
                v._values.add((Object*)kv);
                }
            return v;
            }
        if (name.equals(String.withCString("array")))
            {
            v._kind = (u32)PL_ARRAY;
            if (empty)
                return v;
            while (!_bad)
                {
                skipWs();
                if (at("</array"))
                    {
                    skipTag();
                    break;
                    }
                PlistNode* e = value();
                if (e == (PlistNode*)0)
                    {
                    _bad = true;
                    break;
                    }
                v._values.add((Object*)e);
                }
            return v;
            }
        if (name.equals(String.withCString("true")))
            {
            v._kind = (u32)PL_TRUE;
            if (!empty)
                textUntilClose(name);
            return v;
            }
        if (name.equals(String.withCString("false")))
            {
            v._kind = (u32)PL_FALSE;
            if (!empty)
                textUntilClose(name);
            return v;
            }
        String* t = empty ? String.withCString("") : textUntilClose(name);
        if (name.equals(String.withCString("string")))
            v._kind = (u32)PL_STRING;
        else if (name.equals(String.withCString("integer")))
            v._kind = (u32)PL_INTEGER;
        else if (name.equals(String.withCString("real")))
            v._kind = (u32)PL_REAL;
        else if (name.equals(String.withCString("date")))
            v._kind = (u32)PL_DATE;
        else if (name.equals(String.withCString("data")))
            {
            v._kind = (u32)PL_DATA;
            v._bytes = Pem.base64Decode(t);
            }
        else
            {
            _bad = true;
            return (PlistNode*)0;
            }
        v._text = (name.equals(String.withCString("string"))) ? t : t.trimmed();
        return v;
        }

    // ── writing ─────────────────────────────────────────────────────────────
    // The CoreFoundation XML serialisation of `root`, as bytes.
    static Array* xml(PlistNode* root)
        {
        String* s = String.withCString("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                                       "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
                                       "<plist version=\"1.0\">\n");
        Plist.write(s, root, (u32)0);
        s.appendCString("</plist>\n");
        return Bytes.fromString(s);
        }
    static void indent(String* s, u32 n)
        {
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            s.appendByte((u8)9);
        }
    static void escaped(String* s, String* t)
        {
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            {
            u8 c = t.byteAt(i);
            if (c == (u8)'&')
                s.appendCString("&amp;");
            else if (c == (u8)'<')
                s.appendCString("&lt;");
            else if (c == (u8)'>')
                s.appendCString("&gt;");
            else
                s.appendByte(c);
            }
        }
    static i32 keyCmp(String* a, String* b)
        {
        u32 n = a.byteLength() < b.byteLength() ? a.byteLength() : b.byteLength();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            if (a.byteAt(i) < b.byteAt(i))
                return (i32)-1;
            if (a.byteAt(i) > b.byteAt(i))
                return (i32)1;
            }
        if (a.byteLength() < b.byteLength())
            return (i32)-1;
        if (a.byteLength() > b.byteLength())
            return (i32)1;
        return (i32)0;
        }
    static void tagged(String* s, string tag, String* text)
        {
        s.appendCString("<");
        s.appendCString(tag);
        s.appendCString(">");
        Plist.escaped(s, text);
        s.appendCString("</");
        s.appendCString(tag);
        s.appendCString(">\n");
        }
    // CoreFoundation's base64 for <data>: 76 columns, the indent counting
    // eight per tab against the line.
    static void data(String* s, Array* b, u32 ind)
        {
        String* T = String.withCString("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/");
        u32 cap = ind > (u32)8 ? (u32)8 : ind;
        String* line = String.withCString("");
        u32 n = b.count();
        u32 i = (u32)0;
        while (i < n)
            {
            u32 c = Bytes.at(b, i);
            u32 m = i % (u32)3;
            if (m == (u32)0)
                line.appendByte(T.byteAt((c >> (u32)2) & (u32)$3F));
            else if (m == (u32)1)
                line.appendByte(T.byteAt((((Bytes.at(b, i - (u32)1) << (u32)8) | c) >> (u32)4) & (u32)$3F));
            else
                {
                line.appendByte(T.byteAt((((Bytes.at(b, i - (u32)1) << (u32)8) | c) >> (u32)6) & (u32)$3F));
                line.appendByte(T.byteAt(c & (u32)$3F));
                }
            if (line.byteLength() >= (u32)76 - (u32)8 * cap)
                {
                Plist.indent(s, ind);
                s.append(line);
                s.appendCString("\n");
                line = String.withCString("");
                }
            i = i + (u32)1;
            }
        u32 m = n % (u32)3;
        if (m == (u32)1)
            {
            line.appendByte(T.byteAt((Bytes.at(b, n - (u32)1) << (u32)4) & (u32)$30));
            line.appendCString("==");
            }
        else if (m == (u32)2)
            {
            line.appendByte(T.byteAt((Bytes.at(b, n - (u32)1) << (u32)2) & (u32)$3C));
            line.appendCString("=");
            }
        if (line.byteLength() > (u32)0)
            {
            Plist.indent(s, ind);
            s.append(line);
            s.appendCString("\n");
            }
        }
    static void write(String* s, PlistNode* v, u32 ind)
        {
        Plist.indent(s, ind);
        u32 k = v._kind;
        if (k == (u32)PL_DICT)
            {
            if (v._keys.count() == (u32)0)
                {
                s.appendCString("<dict/>\n");
                return;
                }
            s.appendCString("<dict>\n");
            // Insertion sort of the key indices, byte order.
            Array* order = new Array();
            for (u32 i = (u32)0; i < v._keys.count(); i = i + (u32)1)
                {
                String* key = (String*)v._keys.get(i);
                u32 at = order.count();
                for (u32 j = (u32)0; j < order.count(); j = j + (u32)1)
                    {
                    String* o = (String*)v._keys.get(((Number*)order.get(j)).asU32());
                    if (Plist.keyCmp(key, o) < (i32)0)
                        {
                        at = j;
                        break;
                        }
                    }
                order.insert(at, (Object*)Number.withU32(i));
                }
            for (u32 j = (u32)0; j < order.count(); j = j + (u32)1)
                {
                u32 i = ((Number*)order.get(j)).asU32();
                Plist.indent(s, ind + (u32)1);
                Plist.tagged(s, "key", (String*)v._keys.get(i));
                Plist.write(s, (PlistNode*)v._values.get(i), ind + (u32)1);
                }
            Plist.indent(s, ind);
            s.appendCString("</dict>\n");
            return;
            }
        if (k == (u32)PL_ARRAY)
            {
            if (v._values.count() == (u32)0)
                {
                s.appendCString("<array/>\n");
                return;
                }
            s.appendCString("<array>\n");
            for (u32 i = (u32)0; i < v._values.count(); i = i + (u32)1)
                Plist.write(s, (PlistNode*)v._values.get(i), ind + (u32)1);
            Plist.indent(s, ind);
            s.appendCString("</array>\n");
            return;
            }
        if (k == (u32)PL_TRUE)
            {
            s.appendCString("<true/>\n");
            return;
            }
        if (k == (u32)PL_FALSE)
            {
            s.appendCString("<false/>\n");
            return;
            }
        if (k == (u32)PL_STRING)
            Plist.tagged(s, "string", v._text);
        else if (k == (u32)PL_INTEGER)
            Plist.tagged(s, "integer", v._text);
        else if (k == (u32)PL_REAL)
            Plist.tagged(s, "real", v._text);
        else if (k == (u32)PL_DATE)
            Plist.tagged(s, "date", v._text);
        else if (k == (u32)PL_DATA)
            {
            s.appendCString("<data>\n");
            Plist.data(s, v._bytes, ind);
            Plist.indent(s, ind);
            s.appendCString("</data>\n");
            }
        }
    }

// ── provisioning profiles ───────────────────────────────────────────────────
class Profile
    {
    void init(void)
        {
        }
    // The XML plist a .mobileprovision carries: ContentInfo { OID, [0] {
    // SignedData { version, digestAlgorithms, encapContentInfo { OID, [0] {
    // OCTET STRING } } ... } } }. Null when it is not shaped like that.
    static Array* content(Array* mobileProvision)
        {
        DerReader* ci = DerReader.of(mobileProvision).readConstructed();
        if (ci == (DerReader*)0)
            return (Array*)0;
        ci.readTLV(); // signedData OID
        DerReader* ctx0 = ci.readConstructed();
        if (ctx0 == (DerReader*)0)
            return (Array*)0;
        DerReader* sd = ctx0.readConstructed();
        if (sd == (DerReader*)0)
            return (Array*)0;
        sd.readTLV();     // version
        sd.readElement(); // digestAlgorithms
        DerReader* eci = sd.readConstructed();
        if (eci == (DerReader*)0)
            return (Array*)0;
        eci.readTLV(); // eContentType
        DerReader* ectx = eci.readConstructed();
        if (ectx == (DerReader*)0)
            return (Array*)0;
        Array* plist = ectx.readTLV();
        if (plist == (Array*)0 || ectx.lastTag() != (u32)$04)
            return (Array*)0;
        return plist;
        }
    // The profile's Entitlements dictionary as a standalone XML plist, or null.
    static Array* entitlements(Array* mobileProvision)
        {
        Array* plist = Profile.content(mobileProvision);
        if (plist == (Array*)0)
            return (Array*)0;
        PlistNode* root = Plist.parse(plist);
        if (root == (PlistNode*)0 || root.kind() != (u32)PL_DICT)
            return (Array*)0;
        PlistNode* ent = root.get(String.withCString("Entitlements"));
        if (ent == (PlistNode*)0 || ent.kind() != (u32)PL_DICT)
            return (Array*)0;
        return Plist.xml(ent);
        }
    }
