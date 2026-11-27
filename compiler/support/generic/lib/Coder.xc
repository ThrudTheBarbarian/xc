// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

// Coder.xc — keyed archiving of an object graph to JSON, optionally gzipped.
// ===========================================================================
//
// The xc form of NSKeyedArchiver and NSKeyedUnarchiver, in one class. There is
// no separate archiver and unarchiver, and no un-keyed coding: a Coder is
// handed to `encodeWithCoder` while an archive is written and to
// `initWithCoder` while one is read (see Codable.xc), and the class methods
// below are the whole public entry point.
//
//     Data*   blob = Coder.archive(root, (u8)0);   // UTF-8 JSON
//     Data*   gz   = Coder.archive(root, (u8)9);   // the same JSON, gzipped
//     String* text = Coder.archiveJSON(root);
//
//     try   { Object* back = Coder.unarchive(gz); … }
//     catch (CoderError e) { Stdio.printf("%s\n", e.message().cString()); }
//
// ── The format ──────────────────────────────────────────────────────────────
//
// NSKeyedArchiver's object table, written as JSON:
//
//     {"$archiver":"Coder","$version":1,
//      "$top":{"root":{"$ref":1}},
//      "$objects":["$null",
//                  {"$class":"Point","x":3,"y":4,"next":{"$ref":2}},
//                  {"$class":"Point","x":5,"y":6,"next":{"$ref":1}}]}
//
// Every object is written ONCE, at its index in `$objects`, and referred to
// by index everywhere else, so an object shared by two parents stays shared
// and a cycle terminates. Index 0 is always "$null", the reference for null.
// Identity is the object's address: String and Number compare by value, and
// two equal strings that are distinct objects stay distinct.
//
// Scalars (`encodeI32`, `encodeBool`, …) are written inline in the owning
// object's entry. The library's own value types are written in a native JSON
// form instead of through `encodeWithCoder`:
//
//     String   "text"                                  a JSON string
//     Number   42  or  2.5                             a JSON number
//     Data     {"$class":"Data","$base64":"3q2+7w=="}
//     Array    {"$class":"Array","$items":[2,3,0]}     indexes into $objects
//     Set      {"$class":"Set","$items":[4,5]}
//     Map      {"$class":"Map","$keys":[6,7],"$values":[8,0]}
//
// A Number keeps its kind: a float is always written with a `.` or an
// exponent (`3.0`, `1e+300`), an integer never is. Integers are exact over
// the whole 64-bit range. A double is written in the shortest form that reads
// back as the same bits, and read back correctly rounded, so a round trip is
// exact. NaN and the infinities have no JSON spelling: inline they are the
// strings "NaN", "Infinity" and "-Infinity"; as a Number object they are
// {"$class":"Number","$double":"NaN"}. A String that is not valid UTF-8 cannot
// be a JSON string, and is written as {"$class":"String","$base64":…}.
//
// A key beginning with `$` is reserved for the format and written with an
// extra `$` in front, so a class may still use one. A subclass of String,
// Number, Data, Array, Map or Set is archived as that class.
//
// ── Compression ─────────────────────────────────────────────────────────────
//
// `archive(root, level)` with a level of 1 to 9 gzips the finished JSON once,
// at that level (RFC 1951 deflate in an RFC 1952 wrapper), and `unarchive`
// recognises the gzip magic by itself. Both directions are implemented here —
// LZ77 over hash chains, fixed and dynamic Huffman blocks, and a full inflate —
// so no target needs zlib. The output is what `gzip -d` expects, and `gunzip`
// reads what `gzip` writes; both are also public as `Coder.gzip` and
// `Coder.gunzip` for data that is not an archive.
//
// ── Errors ──────────────────────────────────────────────────────────────────
//
// `unarchive`, `unarchiveJSON` and `gunzip` throw a CoderError (see Error.xc)
// for input that is not JSON, not an archive, names a class the program does
// not have, fails its CRC or ends early. Inside `initWithCoder` the decode
// methods never throw: a missing key gives 0, false or null, as in Foundation,
// and a value of the wrong type is remembered and thrown by `unarchive` when
// the graph is finished.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every target except xt6502.

#if ARCH_6502
#error "Coder: archiving is not available on xt6502"
#endif

#import "Foundation.xc"
#import "Error.xc"
#import "Codable.xc"
#import "JSON.xc"
#import "Deflate.xc"

// ── Class names ─────────────────────────────────────────────────────────────
// The two calls that use the compiler's class-name table: the dynamic name of
// an object being written, and a fresh instance of a named class being read.
String* _coder_className(Object* obj)
    {
    return obj.className();
    }

Object* _coder_newInstance(String* name)
    {
    return Object.newInstanceOfClass(name);
    }

// ═════════════════════════════════════════════════════════════════════════════
// CoderError — what unarchive and gunzip throw.
// ═════════════════════════════════════════════════════════════════════════════

class CoderError <Error>
    {
    String* _message;

    void init(String* message)
        {
        _message = message;
        }

    String* message(void)
        {
        return _message;
        }
    }

// ═════════════════════════════════════════════════════════════════════════════
// Coder
// ═════════════════════════════════════════════════════════════════════════════

u8* _coder_b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

class Coder
    {
    bool _decoding;

    // archiving
    Array* _records;    // one JSON text per $objects entry
    Array* _keep;       // every archived object, so no address is reused
    pointer* _idKeys;   // object address -> index in $objects
    u32* _idVals;
    u32 _idCap;
    u32 _idCount;
    String* _cur;       // the entry being written

    // unarchiving
    Array* _nodes;      // the parsed $objects
    Array* _made;       // index -> decoded object
    u8* _state;         // index -> 0 not started, 1 decoded or in progress
    _JSONNode* _rec;    // the entry being read
    String* _error;     // first problem found while decoding


    void init(void)
        {
        _decoding = false;
        _idKeys = (pointer*)0;
        _idVals = (u32*)0;
        _idCap = (u32)0;
        _idCount = (u32)0;
        _state = (u8*)0;
        }

    void dealloc(void)
        {
        _coder_free((pointer)_idKeys);
        _coder_free((pointer)_idVals);
        _coder_free((pointer)_state);
        }

    // ═════════════════════════════════════════════════════════════════════
    // Archiving
    // ═════════════════════════════════════════════════════════════════════

    // The archive of `root` as UTF-8 JSON, or gzipped at `compression` 1-9.
    // Compression 0 is plain JSON.
    static Data* archive(Object* root, u8 compression)
        {
        String* json = Coder.archiveJSON(root);
        if (compression == (u8)0)
            return Data.withString(json);
        u8 level = (compression > (u8)9) ? (u8)9 : compression;
        return Coder._gzipBytes(json.cString(), json.byteLength(), level);
        }

    static String* archiveJSON(Object* root)
        {
        Coder* c = new Coder();
        c._records = new Array();
        c._keep = new Array();
        c._records.add(String.withCString("\"$null\""));
        c._keep.add((Object*)0);
        u32 top = c._ref(root);
        String* out = String.withCString("{\"$archiver\":\"Coder\",\"$version\":1,\"$top\":{\"root\":{\"$ref\":");
        out.append(String.withU32(top));
        out.appendCString("}},\"$objects\":[");
        u32 n = c._records.count();
        for (u32 i = (u32)0; i < n; i++)
            {
            if (i != (u32)0)
                out.appendByte((u8)',');
            out.append((String*)c._records.get(i));
            }
        out.appendCString("]}");
        return out;
        }

    // ── Keyed encoding (from inside encodeWithCoder) ─────────────────────
    void encodeObject(Object* obj, string key)
        {
        if (!_field(key))
            return;
        u32 idx = _ref(obj);
        _cur.appendCString("{\"$ref\":");
        _cur.append(String.withU32(idx));
        _cur.appendByte((u8)'}');
        }

    void encodeBool(bool v, string key)
        {
        if (!_field(key))
            return;
        _cur.appendCString(v ? "true" : "false");
        }

    void encodeI32(i32 v, string key)
        {
        if (!_field(key))
            return;
        _cur.append(String.withI32(v));
        }

    void encodeU32(u32 v, string key)
        {
        if (!_field(key))
            return;
        _cur.append(String.withU32(v));
        }

    void encodeI64(i64 v, string key)
        {
        if (!_field(key))
            return;
        _cur.append(String.withI64(v));
        }

    void encodeU64(u64 v, string key)
        {
        if (!_field(key))
            return;
        _cur.append(String.withU64(v));
        }

    void encodeFloat(float v, string key)
        {
        if (!_field(key))
            return;
        Coder._appendDoubleValue(_cur, (double)v, true);
        }

    void encodeDouble(double v, string key)
        {
        if (!_field(key))
            return;
        Coder._appendDoubleValue(_cur, v, false);
        }

    // Start `"key":` in the current entry. False when not archiving.
    bool _field(string key)
        {
        if (_decoding || _cur == 0)
            return false;
        _cur.appendByte((u8)',');
        Coder._appendKey(_cur, key);
        _cur.appendByte((u8)':');
        return true;
        }

    static void _appendKey(String* s, string key)
        {
        s.appendByte((u8)'"');
        if (key[0] == (u8)'$')
            s.appendByte((u8)'$');
        JSON._appendEscaped(s, key, String._cstringLen(key));
        s.appendByte((u8)'"');
        }

    static void _appendDoubleValue(String* s, double v, bool single)
        {
        u64 bits = _json_dbits(v);
        if (((bits >> (u64)52) & (u64)0x7FF) == (u64)0x7FF)
            {
            if ((bits & (u64)0x000FFFFFFFFFFFFF) != (u64)0)
                s.appendCString("\"NaN\"");
            else if ((bits >> (u64)63) != (u64)0)
                s.appendCString("\"-Infinity\"");
            else
                s.appendCString("\"Infinity\"");
            return;
            }
        _json_appendDouble(s, v, single);
        }



    // ── The object table ─────────────────────────────────────────────────
    static u32 _addrHash(pointer p)
        {
        u32 a = (u32)p;
        a = a ^ (a >> (u32)16);
        a = a * (u32)2246822519;
        a = a ^ (a >> (u32)13);
        return a;
        }

    u32 _idFind(pointer p)
        {
        if (_idCap == (u32)0)
            return (u32)0xFFFFFFFF;
        pointer* keys = _idKeys;
        u32* vals = _idVals;
        u32 mask = _idCap - (u32)1;
        u32 i = Coder._addrHash(p) & mask;
        while (keys[i] != (pointer)0)
            {
            if (keys[i] == p)
                return vals[i];
            i = (i + (u32)1) & mask;
            }
        return (u32)0xFFFFFFFF;
        }

    void _idPut(pointer p, u32 v)
        {
        if ((_idCount + (u32)1) * (u32)2 > _idCap)
            {
            u32 cap = (_idCap == (u32)0) ? (u32)64 : _idCap * (u32)2;
            pointer* oldKeys = _idKeys;
            u32* oldVals = _idVals;
            u32 oldCap = _idCap;
            pointer* nk = new pointer[cap];
            u32* nv = new u32[cap];
            for (u32 i = (u32)0; i < cap; i++)
                nk[i] = (pointer)0;
            _idKeys = nk;
            _idVals = nv;
            _idCap = cap;
            _idCount = (u32)0;
            for (u32 i = (u32)0; i < oldCap; i++)
                {
                if (oldKeys[i] != (pointer)0)
                    _idPut(oldKeys[i], oldVals[i]);
                }
            _coder_free((pointer)oldKeys);
            _coder_free((pointer)oldVals);
            }
        pointer* keys = _idKeys;
        u32* vals = _idVals;
        u32 mask = _idCap - (u32)1;
        u32 i = Coder._addrHash(p) & mask;
        while (keys[i] != (pointer)0)
            i = (i + (u32)1) & mask;
        keys[i] = p;
        vals[i] = v;
        _idCount = _idCount + (u32)1;
        }

    // The $objects index of `obj`, writing its entry the first time.
    u32 _ref(Object* obj)
        {
        if (obj == 0)
            return (u32)0;
        u32 idx = _idFind((pointer)obj);
        if (idx != (u32)0xFFFFFFFF)
            return idx;
        idx = _records.count();
        _records.add((Object*)0);
        _keep.add(obj);
        _idPut((pointer)obj, idx);
        String* saved = _cur;
        _cur = String.withCString("");
        _write(obj);
        _records.set(idx, _cur);
        _cur = saved;
        return idx;
        }

    // One $objects entry into _cur.
    void _write(Object* obj)
        {
        String* str = (String* ?)obj;
        if (str != 0)
            {
            if (str.isValidUtf8())
                {
                JSON._appendString(_cur, str.cString(), str.byteLength());
                }
            else
                {
                _cur.appendCString("{\"$class\":\"String\",\"$base64\":\"");
                Coder._appendBase64(_cur, str.cString(), str.byteLength());
                _cur.appendCString("\"}");
                }
            return;
            }
        Number* num = (Number* ?)obj;
        if (num != 0)
            {
            if (!num.isFloat())
                {
                _cur.append(String.withI64(num.asI64()));
                return;
                }
            double d = num.asDouble();
            u64 bits = _json_dbits(d);
            if (((bits >> (u64)52) & (u64)0x7FF) == (u64)0x7FF)
                {
                _cur.appendCString("{\"$class\":\"Number\",\"$double\":");
                Coder._appendDoubleValue(_cur, d, false);
                _cur.appendByte((u8)'}');
                return;
                }
            _json_appendDouble(_cur, d, false);
            return;
            }
        Data* data = (Data* ?)obj;
        if (data != 0)
            {
            _cur.appendCString("{\"$class\":\"Data\",\"$base64\":\"");
            Coder._appendBase64(_cur, data.bytes(), data.length());
            _cur.appendCString("\"}");
            return;
            }
        Array* arr = (Array* ?)obj;
        if (arr != 0)
            {
            _cur.appendCString("{\"$class\":\"Array\",\"$items\":");
            _writeRefs(arr);
            _cur.appendByte((u8)'}');
            return;
            }
        Map* map = (Map* ?)obj;
        if (map != 0)
            {
            _cur.appendCString("{\"$class\":\"Map\",\"$keys\":");
            _writeRefs(map.allKeys());
            _cur.appendCString(",\"$values\":");
            _writeRefs(map.allValues());
            _cur.appendByte((u8)'}');
            return;
            }
        Set* set = (Set* ?)obj;
        if (set != 0)
            {
            _cur.appendCString("{\"$class\":\"Set\",\"$items\":");
            _writeRefs(set.allObjects());
            _cur.appendByte((u8)'}');
            return;
            }
        // Any other class: its name, then whatever its encodeWithCoder writes.
        // Each field adds its own leading ',', which the name has already
        // made legal.
        String* name = _coder_className(obj);
        _cur.appendCString("{\"$class\":");
        if (name == 0)
            _cur.appendCString("null");
        else
            JSON._appendString(_cur, name.cString(), name.byteLength());
        obj.encodeWithCoder(self);
        _cur.appendByte((u8)'}');
        }

    // `[i, j, …]` — each element's index, written after the elements (which
    // may need entries of their own) have been placed.
    void _writeRefs(Array* items)
        {
        u32 n = items.count();
        String* refs = String.withCString("[");
        for (u32 i = (u32)0; i < n; i++)
            {
            if (i != (u32)0)
                refs.appendByte((u8)',');
            refs.append(String.withU32(_ref(items.get(i))));
            }
        refs.appendByte((u8)']');
        _cur.append(refs);
        }

    // ═════════════════════════════════════════════════════════════════════
    // Unarchiving
    // ═════════════════════════════════════════════════════════════════════

    // The root object of an archive written by `archive`, compressed or not.
    static Object* unarchive(Data* data) throws
        {
        if (data == 0)
            throw new CoderError(String.withCString("Coder: no data"));
        u8* b = data.bytes();
        u32 n = data.length();
        if (n >= (u32)2 && b[0] == (u8)$1F && b[1] == (u8)$8B)
            {
            Data* plain = Coder.gunzip(data);
            return Coder._unarchiveBytes(plain.bytes(), plain.length());
            }
        return Coder._unarchiveBytes(b, n);
        }

    static Object* unarchiveJSON(String* json) throws
        {
        if (json == 0)
            throw new CoderError(String.withCString("Coder: no JSON"));
        return Coder._unarchiveBytes(json.cString(), json.byteLength());
        }

    static Object* _unarchiveBytes(u8* p, u32 n) throws
        {
        _JSONReader* parser = new _JSONReader();
        _JSONNode* doc = parser.parse(p, n);
        if (doc == 0)
            throw new CoderError(parser._error);
        _JSONNode* archiver = doc.field("$archiver", false);
        if (archiver == 0 || !archiver.isString("Coder"))
            throw new CoderError(String.withCString("Coder: not a Coder archive"));
        _JSONNode* version = doc.field("$version", false);
        if (version == 0 || !version.isInteger())
            throw new CoderError(String.withCString("Coder: the archive has no version"));
        if (!version.textIs("1"))
            throw new CoderError(String.withCString("Coder: the archive's version is not 1"));
        _JSONNode* objects = doc.field("$objects", false);
        _JSONNode* top = doc.field("$top", false);
        if (objects == 0 || objects.kind != JK_ARRAY || top == 0)
            throw new CoderError(String.withCString("Coder: the archive has no object table"));
        _JSONNode* rootRef = top.field("root", false);
        if (rootRef == 0)
            throw new CoderError(String.withCString("Coder: the archive has no root"));

        Coder* c = new Coder();
        c._decoding = true;
        c._nodes = objects.items;
        u32 count = objects.items.count();
        c._made = Array.withCapacity(count);
        u8* state = new u8[count + (u32)1];
        for (u32 i = (u32)0; i < count; i++)
            {
            c._made.add((Object*)0);
            state[i] = (u8)0;
            }
        c._state = state;
        u32 idx = c._refIndex(rootRef, "root");
        Object* root = (Object*)0;
        if (c._error == 0)
            root = c._object(idx);
        if (c._error != 0)
            throw new CoderError(c._error);
        return root;
        }

    void _fail(string what, string key, string why)
        {
        if (_error != 0)
            return;
        _error = String.withCString("Coder: ");
        _error.appendCString(what);
        if (key != (string)0)
            {
            _error.appendCString(" '");
            _error.appendCString(key);
            _error.appendCString("'");
            }
        _error.appendCString(why);
        }

    // The index a `{"$ref":n}` node points at, or 0 (null) with an error set.
    u32 _refIndex(_JSONNode* node, string key)
        {
        _JSONNode* r = node.field("$ref", false);
        if (r == 0 || !r.isInteger())
            {
            _fail("value for key", key, " is not an object reference");
            return (u32)0;
            }
        return Coder._indexOf(r);
        }

    // An integer node as an index; out-of-range values become 0xFFFFFFFF,
    // which the caller's bounds check rejects.
    static u32 _indexOf(_JSONNode* r)
        {
        if (r == 0 || !r.isInteger())
            return (u32)0xFFFFFFFF;
        u8* b = r.text.cString();
        u32 n = r.text.byteLength();
        if (b[0] == (u8)'-' || n > (u32)9)
            return (u32)0xFFFFFFFF;
        u32 v = (u32)0;
        for (u32 i = (u32)0; i < n; i++)
            v = v * (u32)10 + (u32)(b[i] - (u8)'0');
        return v;
        }

    // The object at $objects index `idx`, decoding it the first time.
    Object* _object(u32 idx)
        {
        if (idx == (u32)0)
            return (Object*)0;
        if (idx >= _nodes.count())
            {
            _fail("reference out of range", (string)0, "");
            return (Object*)0;
            }
        u8* state = _state;
        if (state[idx] != (u8)0)
            return _made.get(idx);
        state[idx] = (u8)1;
        _JSONNode* node = (_JSONNode*)_nodes.get(idx);
        if (node.kind == JK_STRING)
            {
            Object* s = String.withBytes(node.text.cString(), node.text.byteLength());
            _made.set(idx, s);
            return s;
            }
        if (node.kind == JK_NUMBER)
            {
            Object* v = (Object*)JSON._numberOf(node);
            _made.set(idx, v);
            return v;
            }
        if (node.kind != JK_OBJECT)
            {
            _fail("an entry in $objects is not a value", (string)0, "");
            return (Object*)0;
            }
        _JSONNode* cls = node.field("$class", false);
        if (cls == 0 || cls.kind != JK_STRING)
            {
            _fail("an entry in $objects has no class", (string)0, "");
            return (Object*)0;
            }
        if (cls.isString("String") || cls.isString("Data"))
            {
            _JSONNode* b64 = node.field("$base64", false);
            Data* bytes = (b64 == 0) ? (Data*)0 : Coder._decodeBase64(b64.text);
            if (bytes == 0)
                {
                _fail("bad base64 in", (string)0, " an archived String or Data");
                return (Object*)0;
                }
            Object* v = (Object*)bytes;
            if (cls.isString("String"))
                v = (Object*)bytes.stringValue();
            _made.set(idx, v);
            return v;
            }
        if (cls.isString("Number"))
            {
            _JSONNode* d = node.field("$double", false);
            if (d == 0)
                {
                _fail("an archived Number has no value", (string)0, "");
                return (Object*)0;
                }
            Object* v = (Object*)Number.withDouble(_doubleOf(d, "$double"));
            _made.set(idx, v);
            return v;
            }
        if (cls.isString("Array"))
            {
            Array* a = new Array();
            _made.set(idx, a);
            _JSONNode* items = node.field("$items", false);
            if (!_checkRefs(items))
                return a;
            u32 n = items.items.count();
            for (u32 i = (u32)0; i < n; i++)
                a.add(_object(Coder._indexOf((_JSONNode*)items.items.get(i))));
            return a;
            }
        if (cls.isString("Set"))
            {
            Set* s = new Set();
            _made.set(idx, s);
            _JSONNode* items = node.field("$items", false);
            if (!_checkRefs(items))
                return s;
            u32 n = items.items.count();
            for (u32 i = (u32)0; i < n; i++)
                {
                Object* e = _object(Coder._indexOf((_JSONNode*)items.items.get(i)));
                if (e != 0)
                    s.add((Hashable*)e);
                }
            return s;
            }
        if (cls.isString("Map"))
            {
            Map* m = new Map();
            _made.set(idx, m);
            _JSONNode* keys = node.field("$keys", false);
            _JSONNode* vals = node.field("$values", false);
            if (!_checkRefs(keys) || !_checkRefs(vals))
                return m;
            u32 n = keys.items.count();
            if (vals.items.count() != n)
                {
                _fail("an archived Map has unequal key and value counts", (string)0, "");
                return m;
                }
            for (u32 i = (u32)0; i < n; i++)
                {
                Object* k = _object(Coder._indexOf((_JSONNode*)keys.items.get(i)));
                Object* v = _object(Coder._indexOf((_JSONNode*)vals.items.get(i)));
                if (k != 0)
                    m.set((Hashable*)k, v);
                }
            return m;
            }
        Object* obj = _coder_newInstance(cls.text);
        if (obj == 0)
            {
            _fail("unknown class", cls.text.cString(), "");
            return (Object*)0;
            }
        // Registered BEFORE initWithCoder, so a reference back to this object
        // from inside its own graph finds it.
        _made.set(idx, obj);
        _JSONNode* saved = _rec;
        _rec = node;
        obj.initWithCoder(self);
        _rec = saved;
        return obj;
        }

    bool _checkRefs(_JSONNode* list)
        {
        if (list == 0 || list.kind != JK_ARRAY)
            {
            _fail("an archived collection has no item list", (string)0, "");
            return false;
            }
        u32 n = list.items.count();
        for (u32 i = (u32)0; i < n; i++)
            {
            _JSONNode* r = (_JSONNode*)list.items.get(i);
            if (!r.isInteger())
                {
                _fail("an archived collection has a bad reference", (string)0, "");
                return false;
                }
            }
        return true;
        }



    // ── Keyed decoding (from inside initWithCoder) ───────────────────────
    _JSONNode* _lookup(string key)
        {
        if (!_decoding || _rec == 0)
            return (_JSONNode*)0;
        return _rec.field(key, key[0] == (u8)'$');
        }

    bool containsKey(string key)
        {
        return _lookup(key) != 0;
        }

    Object* decodeObject(string key)
        {
        _JSONNode* v = _lookup(key);
        if (v == 0)
            return (Object*)0;
        if (v.kind != JK_OBJECT)
            {
            _fail("value for key", key, " is not an object reference");
            return (Object*)0;
            }
        u32 idx = _refIndex(v, key);
        if (_error != 0)
            return (Object*)0;
        return _object(idx);
        }

    bool decodeBool(string key)
        {
        _JSONNode* v = _lookup(key);
        if (v == 0)
            return false;
        if (v.kind == JK_TRUE)
            return true;
        if (v.kind != JK_FALSE)
            _fail("value for key", key, " is not a bool");
        return false;
        }

    // A signed value in [lo, hi].
    i64 _signed(string key, i64 lo, i64 hi)
        {
        _JSONNode* v = _lookup(key);
        if (v == 0)
            return (i64)0;
        if (v.kind != JK_NUMBER)
            {
            _fail("value for key", key, " is not a number");
            return (i64)0;
            }
        i64 r = (i64)0;
        if (v.isInteger())
            {
            bool neg = false;
            bool over = false;
            u64 mag = JSON._magnitude(v.text, &neg, &over);
            if (over || (!neg && mag > (u64)0x7FFFFFFFFFFFFFFF) || (neg && mag > (u64)0x8000000000000000))
                {
                _fail("value for key", key, " is out of range");
                return (i64)0;
                }
            r = neg ? (i64)((u64)0 - mag) : (i64)mag;
            }
        else
            {
            double d = _json_parseDouble(v.text.cString(), v.text.byteLength());
            if (!(d >= -9223372036854775808.0d && d < 9223372036854775808.0d))
                {
                _fail("value for key", key, " is out of range");
                return (i64)0;
                }
            r = (i64)d;
            }
        if (r < lo || r > hi)
            {
            _fail("value for key", key, " is out of range");
            return (i64)0;
            }
        return r;
        }

    i32 decodeI32(string key)
        {
        return (i32)_signed(key, (i64)-2147483648, (i64)2147483647);
        }

    u32 decodeU32(string key)
        {
        return (u32)_signed(key, (i64)0, (i64)4294967295);
        }

    i64 decodeI64(string key)
        {
        return _signed(key, (i64)0x8000000000000000, (i64)0x7FFFFFFFFFFFFFFF);
        }

    u64 decodeU64(string key)
        {
        _JSONNode* v = _lookup(key);
        if (v == 0)
            return (u64)0;
        if (v.kind != JK_NUMBER)
            {
            _fail("value for key", key, " is not a number");
            return (u64)0;
            }
        if (v.isInteger())
            {
            bool neg = false;
            bool over = false;
            u64 mag = JSON._magnitude(v.text, &neg, &over);
            if (over || (neg && mag != (u64)0))
                {
                _fail("value for key", key, " is out of range");
                return (u64)0;
                }
            return mag;
            }
        double d = _json_parseDouble(v.text.cString(), v.text.byteLength());
        if (!(d >= 0.0d && d < 18446744073709551616.0d))
            {
            _fail("value for key", key, " is out of range");
            return (u64)0;
            }
        return (u64)d;
        }

    float decodeFloat(string key)
        {
        return (float)decodeDouble(key);
        }

    double decodeDouble(string key)
        {
        _JSONNode* v = _lookup(key);
        if (v == 0)
            return 0.0d;
        return _doubleOf(v, key);
        }

    double _doubleOf(_JSONNode* v, string key)
        {
        if (v.kind == JK_NUMBER)
            return _json_parseDouble(v.text.cString(), v.text.byteLength());
        if (v.isString("NaN"))
            return _json_dfrom((u64)0x7FF8000000000000);
        if (v.isString("Infinity"))
            return _json_dfrom((u64)0x7FF0000000000000);
        if (v.isString("-Infinity"))
            return _json_dfrom((u64)0xFFF0000000000000);
        _fail("value for key", key, " is not a number");
        return 0.0d;
        }

    // ═════════════════════════════════════════════════════════════════════
    // Base64 (RFC 4648, with padding)
    // ═════════════════════════════════════════════════════════════════════

    static void _appendBase64(String* s, u8* p, u32 n)
        {
        u8* t = _coder_b64;
        u32 i = (u32)0;
        while (i + (u32)3 <= n)
            {
            u32 v = ((u32)p[i] << (u32)16) | ((u32)p[i + (u32)1] << (u32)8) | (u32)p[i + (u32)2];
            s.appendByte(t[(v >> (u32)18) & (u32)63]);
            s.appendByte(t[(v >> (u32)12) & (u32)63]);
            s.appendByte(t[(v >> (u32)6) & (u32)63]);
            s.appendByte(t[v & (u32)63]);
            i = i + (u32)3;
            }
        u32 rest = n - i;
        if (rest == (u32)1)
            {
            u32 v = (u32)p[i] << (u32)16;
            s.appendByte(t[(v >> (u32)18) & (u32)63]);
            s.appendByte(t[(v >> (u32)12) & (u32)63]);
            s.appendCString("==");
            }
        else if (rest == (u32)2)
            {
            u32 v = ((u32)p[i] << (u32)16) | ((u32)p[i + (u32)1] << (u32)8);
            s.appendByte(t[(v >> (u32)18) & (u32)63]);
            s.appendByte(t[(v >> (u32)12) & (u32)63]);
            s.appendByte(t[(v >> (u32)6) & (u32)63]);
            s.appendByte((u8)'=');
            }
        }

    static u32 _b64Value(u8 c)
        {
        if (c >= (u8)'A' && c <= (u8)'Z')
            return (u32)(c - (u8)'A');
        if (c >= (u8)'a' && c <= (u8)'z')
            return (u32)(c - (u8)'a') + (u32)26;
        if (c >= (u8)'0' && c <= (u8)'9')
            return (u32)(c - (u8)'0') + (u32)52;
        if (c == (u8)'+')
            return (u32)62;
        if (c == (u8)'/')
            return (u32)63;
        return (u32)0xFF;
        }

    // Null when the text is not base64.
    static Data* _decodeBase64(String* text)
        {
        if (text == 0)
            return (Data*)0;
        u8* p = text.cString();
        u32 n = text.byteLength();
        if ((n & (u32)3) != (u32)0)
            return (Data*)0;
        Data* out = Data.withCapacity((n / (u32)4) * (u32)3);
        u32 i = (u32)0;
        while (i < n)
            {
            u32 pad = (u32)0;
            u32 v = (u32)0;
            for (u32 k = (u32)0; k < (u32)4; k++)
                {
                u8 c = p[i + k];
                u32 d = (u32)0;
                if (c == (u8)'=' && i + (u32)4 == n && k >= (u32)2)
                    {
                    pad = pad + (u32)1;
                    }
                else
                    {
                    if (pad != (u32)0)
                        return (Data*)0;
                    d = Coder._b64Value(c);
                    if (d == (u32)0xFF)
                        return (Data*)0;
                    }
                v = (v << (u32)6) | d;
                }
            out.appendByte((u8)(v >> (u32)16));
            if (pad < (u32)2)
                out.appendByte((u8)(v >> (u32)8));
            if (pad < (u32)1)
                out.appendByte((u8)v);
            i = i + (u32)4;
            }
        return out;
        }

    // ═════════════════════════════════════════════════════════════════════
    // gzip (RFC 1952)
    // ═════════════════════════════════════════════════════════════════════

    // The CRC-32 gzip uses (Deflate.xc's CoderCrc).
    static u32 crc32(u8* p, u32 n)
        {
        return CoderCrc.crc32(p, n);
        }

    // `data` gzipped at `level` (1 fastest, 9 smallest; 0 stores it
    // uncompressed inside the gzip wrapper).
    static Data* gzip(Data* data, u8 level)
        {
        if (data == 0)
            return Coder._gzipBytes((u8*)0, (u32)0, level);
        return Coder._gzipBytes(data.bytes(), data.length(), level);
        }

    static void _appendLE32(Data* d, u32 v)
        {
        d.appendByte((u8)(v & (u32)$FF));
        d.appendByte((u8)((v >> (u32)8) & (u32)$FF));
        d.appendByte((u8)((v >> (u32)16) & (u32)$FF));
        d.appendByte((u8)(v >> (u32)24));
        }

    static Data* _gzipBytes(u8* p, u32 n, u8 level)
        {
        Data* out = Data.withCapacity(n / (u32)3 + (u32)64);
        out.appendByte((u8)$1F);
        out.appendByte((u8)$8B);
        out.appendByte((u8)8);        // deflate
        out.appendByte((u8)0);        // no flags
        Coder._appendLE32(out, (u32)0); // no modification time
        u8 xfl = (u8)0;
        if (level == (u8)9)
            xfl = (u8)2;
        else if (level == (u8)1)
            xfl = (u8)4;
        out.appendByte(xfl);
        out.appendByte((u8)255);      // operating system unknown
        CoderDeflate.deflate(p, n, (level > (u8)9) ? (u8)9 : level, out);
        Coder._appendLE32(out, Coder.crc32(p, n));
        Coder._appendLE32(out, n);
        return out;
        }

    static u32 _le32(u8* p)
        {
        return (u32)p[0] | ((u32)p[1] << (u32)8) | ((u32)p[2] << (u32)16) | ((u32)p[3] << (u32)24);
        }

    // The contents of the first member of a gzip stream.
    static Data* gunzip(Data* data) throws
        {
        if (data == 0)
            throw new CoderError(String.withCString("gzip: no data"));
        u8* p = data.bytes();
        u32 n = data.length();
        if (n < (u32)18 || p[0] != (u8)$1F || p[1] != (u8)$8B)
            throw new CoderError(String.withCString("gzip: not gzip data"));
        if (p[2] != (u8)8)
            throw new CoderError(String.withCString("gzip: unknown compression method"));
        u8 flg = p[3];
        u32 pos = (u32)10;
        if ((flg & (u8)4) != (u8)0)
            {
            if (pos + (u32)2 > n)
                throw new CoderError(String.withCString("gzip: data ends early"));
            pos = pos + (u32)2 + ((u32)p[pos] | ((u32)p[pos + (u32)1] << (u32)8));
            }
        if ((flg & (u8)8) != (u8)0)
            {
            while (pos < n && p[pos] != (u8)0)
                pos = pos + (u32)1;
            pos = pos + (u32)1;
            }
        if ((flg & (u8)16) != (u8)0)
            {
            while (pos < n && p[pos] != (u8)0)
                pos = pos + (u32)1;
            pos = pos + (u32)1;
            }
        if ((flg & (u8)2) != (u8)0)
            pos = pos + (u32)2;
        if (pos >= n)
            throw new CoderError(String.withCString("gzip: data ends early"));
        CoderInflate* inf = new CoderInflate();
        u32 used = inf.run(&p[pos], n - pos);
        if (inf._error != (string)0)
            {
            String* msg = String.withCString("gzip: ");
            msg.appendCString(inf._error);
            throw new CoderError(msg);
            }
        pos = pos + used;
        if (pos + (u32)8 > n)
            throw new CoderError(String.withCString("gzip: data ends early"));
        u32 crc = Coder._le32(&p[pos]);
        u32 size = Coder._le32(&p[pos + (u32)4]);
        if (crc != Coder.crc32(inf._out, inf._len))
            throw new CoderError(String.withCString("gzip: CRC mismatch"));
        if (size != inf._len)
            throw new CoderError(String.withCString("gzip: length mismatch"));
        return Data.withBytes(inf._out, inf._len);
        }
    }
