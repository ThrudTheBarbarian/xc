// Iface.xc — the .xtc.iface importer, ported (separate-compilation stage 3).
// =========================================================================
//
// The interface a module leaves beside its object (`xcc -c` writes
// `<out>.xtc.iface`) is a JSON record of its classes, protocols, functions,
// globals and slot numbering. The reference driver reconstructs typed
// declarations from it (XTInterfaceImporter) so a client compiles against the
// module WITHOUT its source; this is the port of that reader, and what makes
// a category on an external class exist in the self-hosted compiler at all —
// the mirror the design doc said was missing.
//
// SCOPE: the side-file flow only. A `.dylib`/`.so` carries the same JSON in a
// Mach-O/ELF section; the port has no binary readers, so those imports are
// refused loudly by the caller (xtfe) rather than silently dropped.
//
// The JSON here is NSJSONSerialization's output — objects, arrays, strings,
// numbers, true/false — so the parser below speaks exactly that much JSON
// and nothing more.

#import "Foundation.xc"
#import "Node.xc"

// ── A minimal JSON DOM ──────────────────────────────────────────────────
// Kinds: 0 null, 1 bool, 2 number, 3 string, 4 array, 5 object.
class JsonVal
    {
    u8 _kind;
    bool _b;
    i64 _n;
    String* _s;
    Array* _items; // array: of JsonVal@ · object: parallel with _keys
    Array* _keys;  // object member names, in file order

    void init(void)
        {
        _kind = (u8)0;
        }

    u8 kind(void)
        {
        return _kind;
        }
    bool asBool(void)
        {
        return _b;
        }
    i64 asNum(void)
        {
        return _n;
        }
    String* asStr(void)
        {
        return _s;
        }
    u32 count(void)
        {
        return _items == 0 ? (u32)0 : _items.count();
        }
    JsonVal* at(u32 i)
        {
        return (JsonVal*)_items.get(i);
        }

    JsonVal* member(u8* name)
        {
        if (_keys == 0)
            return (JsonVal*)0;
        String* want = String.withCString(name);
        for (u32 i = (u32)0; i < _keys.count(); i = i + (u32)1)
            if (((String*)_keys.get(i)).equals(want))
                return (JsonVal*)_items.get(i);
        return (JsonVal*)0;
        }
    String* memberStr(u8* name)
        {
        JsonVal* v = member(name);
        return (v == 0 || v._kind != (u8)3) ? (String*)0 : v._s;
        }
    bool memberBool(u8* name)
        {
        JsonVal* v = member(name);
        return v != 0 && v._kind == (u8)1 && v._b;
        }

    static JsonVal* withKind(u8 k)
        {
        JsonVal* v = new JsonVal();
        v._kind = k;
        if (k == (u8)4 || k == (u8)5)
            v._items = new Array();
        if (k == (u8)5)
            v._keys = new Array();
        return v;
        }
    }

    class JsonParser
    {
    String* _src;
    u32 _pos;
    bool _failed;

    void init(void)
        {
        _pos = (u32)0;
        _failed = false;
        }

    static JsonVal* parse(String* text)
        {
        JsonParser* p = new JsonParser();
        p._src = text;
        p.skipWs();
        JsonVal* v = p.value();
        return p._failed ? (JsonVal*)0 : v;
        }

    u8 peek(void)
        {
        return _pos < _src.byteLength() ? _src.byteAt(_pos) : (u8)0;
        }
    u8 take(void)
        {
        u8 c = peek();
        _pos = _pos + (u32)1;
        return c;
        }
    void skipWs(void)
        {
        while (_pos < _src.byteLength())
            {
            u8 c = _src.byteAt(_pos);
            if (c != (u8)' ' && c != (u8)9 && c != (u8)10 && c != (u8)13)
                return;
            _pos = _pos + (u32)1;
            }
        }

    JsonVal* value(void)
        {
        skipWs();
        u8 c = peek();
        if (c == (u8)'{')
            return object();
        if (c == (u8)'[')
            return array();
        if (c == (u8)'"')
            {
            JsonVal* v = JsonVal.withKind((u8)3);
            v._s = str();
            return v;
            }
        if (c == (u8)'t')
            {
            skipWord((u32)4);
            JsonVal* v = JsonVal.withKind((u8)1);
            v._b = true;
            return v;
            }
        if (c == (u8)'f')
            {
            skipWord((u32)5);
            JsonVal* v = JsonVal.withKind((u8)1);
            v._b = false;
            return v;
            }
        if (c == (u8)'n')
            {
            skipWord((u32)4);
            return JsonVal.withKind((u8)0);
            }
        return number();
        }

    void skipWord(u32 n)
        {
        _pos = _pos + n;
        }

    JsonVal* object(void)
        {
        take(); // '{'
        JsonVal* o = JsonVal.withKind((u8)5);
        skipWs();
        if (peek() == (u8)'}')
            {
            take();
            return o;
            }
        while (!_failed)
            {
            skipWs();
            String* k = str();
            skipWs();
            if (take() != (u8)':')
                {
                _failed = true;
                return o;
                }
            JsonVal* v = value();
            o._keys.add((Object*)k);
            o._items.add((Object*)v);
            skipWs();
            u8 c = take();
            if (c == (u8)'}')
                return o;
            if (c != (u8)',')
                {
                _failed = true;
                return o;
                }
            }
        return o;
        }

    JsonVal* array(void)
        {
        take(); // '['
        JsonVal* a = JsonVal.withKind((u8)4);
        skipWs();
        if (peek() == (u8)']')
            {
            take();
            return a;
            }
        while (!_failed)
            {
            JsonVal* v = value();
            a._items.add((Object*)v);
            skipWs();
            u8 c = take();
            if (c == (u8)']')
                return a;
            if (c != (u8)',')
                {
                _failed = true;
                return a;
                }
            }
        return a;
        }

    String* str(void)
        {
        if (take() != (u8)'"')
            {
            _failed = true;
            return String.withCString("");
            }
        String* out = String.withCString("");
        while (_pos < _src.byteLength())
            {
            u8 c = take();
            if (c == (u8)'"')
                return out;
            // '\'
            if (c == (u8)92)
                {
                u8 e = take();
                if (e == (u8)'n')
                    out.appendByte((u8)10);
                else if (e == (u8)'t')
                    out.appendByte((u8)9);
                else if (e == (u8)'r')
                    out.appendByte((u8)13);
                // \uXXXX — ASCII range only
                else if (e == (u8)'u')
                    {
                    u32 v = (u32)0;
                    for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
                        {
                        u8 h = take();
                        u32 d = (u32)0;
                        if (h >= (u8)'0' && h <= (u8)'9')
                            d = (u32)(h - (u8)'0');
                        else if (h >= (u8)'a' && h <= (u8)'f')
                            d = (u32)(h - (u8)'a') + (u32)10;
                        else if (h >= (u8)'A' && h <= (u8)'F')
                            d = (u32)(h - (u8)'A') + (u32)10;
                        v = v * (u32)16 + d;
                        }
                    out.appendByte((u8)v);
                    }
                else
                    out.appendByte(e); // \" \\ \/ literal
                continue;
                }
            out.appendByte(c);
            }
        _failed = true;
        return out;
        }

    JsonVal* number(void)
        {
        JsonVal* v = JsonVal.withKind((u8)2);
        bool neg = false;
        if (peek() == (u8)'-')
            {
            take();
            neg = true;
            }
        i64 n = (i64)0;
        while (peek() >= (u8)'0' && peek() <= (u8)'9')
            n = n * (i64)10 + (i64)(take() - (u8)'0');
        // A fraction/exponent never appears in an iface; consume defensively.
        if (peek() == (u8)'.')
            {
            take();
            while (peek() >= (u8)'0' && peek() <= (u8)'9')
                take();
            }
        v._n = neg ? (i64)0 - n : n;
        return v;
        }
    }

    // ── The interface reader ────────────────────────────────────────────────
    // Reads one `.xtc.iface`, reconstructs declaration NODES (classes, protocols,
    // free functions, globals, enums, structs, typedefs) marked NF_EXTERNAL, and
    // exposes the module's slot numbering for the Vtable to ADOPT — a client
    // re-deriving its own numbering is the classic cross-module dispatch bug.
    class IfaceImport
    {
    Array* _decls;     // of Node@ — reconstructed declarations, file order
    Map* _methodSlots; // label ("_cls_C_m") -> Number(slot)
    // The slots the library assigned to classes it does NOT export — the
    // AMBIENT ones (String, Object, …). Not declarations, so not merged with
    // methodSlots: an ABI assumption the client has to honour, nothing more.
    Map* _ambientSlots;
    Map* _protoSlots; // proto -> Map(method -> Number(slot))

    void init(void)
        {
        _decls = new Array();
        _methodSlots = new Map();
        _ambientSlots = new Map();
        _protoSlots = new Map();
        }

    Array* decls(void)
        {
        return _decls;
        }
    Map* methodSlots(void)
        {
        return _methodSlots;
        }
    Map* ambientSlots(void)
        {
        return _ambientSlots;
        }
    Map* protoSlots(void)
        {
        return _protoSlots;
        }

    // The `xtc.iface` CUSTOM SECTION of a wasm module, as text — the wasm
    // analogue of the ELF section, written by `--emit-lib`. Returns null when
    // the file is not a wasm module or carries no such section, so the caller
    // can say which of the two it was.
    //
    // Only the section HEADERS are walked: id, then a LEB128 length, then the
    // body. A custom section (id 0) starts with its own LEB128-prefixed name.
    // Nothing else in the module is decoded — a reader that understood the
    // whole format would be a second wasm parser to keep in step with the
    // writer, and this needs to know one thing.
    static String* wasmIfaceSection(String* path)
        {
        Data* d = Files.readData(path);
        if (d == (Data*)0 || d.length() < (u32)8)
            return (String*)0;
        if (d.byteAt((u32)0) != (u8)0 || d.byteAt((u32)1) != (u8)$61 || d.byteAt((u32)2) != (u8)$73 || d.byteAt((u32)3) != (u8)$6D)
            return (String*)0; // not "\0asm"
        u32 i = (u32)8;
        while (i < d.length())
            {
            u8 id = d.byteAt(i);
            i = i + (u32)1;
            u32 len = (u32)0;
            u32 shift = (u32)0;
            while (i < d.length())
                {
                u8 b = d.byteAt(i);
                i = i + (u32)1;
                len = len | (((u32)(b & (u8)$7F)) << shift);
                shift = shift + (u32)7;
                if ((b & (u8)$80) == (u8)0)
                    break;
                }
            if (i + len > d.length())
                return (String*)0; // truncated
            u32 end = i + len;
            if (id == (u8)0)
                {
                u32 j = i;
                u32 nlen = (u32)0;
                u32 nsh = (u32)0;
                while (j < end)
                    {
                    u8 b = d.byteAt(j);
                    j = j + (u32)1;
                    nlen = nlen | (((u32)(b & (u8)$7F)) << nsh);
                    nsh = nsh + (u32)7;
                    if ((b & (u8)$80) == (u8)0)
                        break;
                    }
                String* nm = new String();
                for (u32 k = (u32)0; k < nlen && j + k < end; k = k + (u32)1)
                    nm.appendByte(d.byteAt(j + k));
                if (nm.equals(String.withCString("xtc.iface")))
                    {
                    String* out = new String();
                    for (u32 k = j + nlen; k < end; k = k + (u32)1)
                        out.appendByte(d.byteAt(k));
                    return out;
                    }
                }
            i = end;
            }
        return (String*)0;
        }

    // The `__XTC,__iface` SECTION of a Mach-O dylib, as text — the Mach-O
    // analogue of the wasm custom section. Only the load commands are walked:
    // header (32 bytes), then ncmds commands, each `cmd, cmdsize, …`. A
    // segment_command_64 is followed by its section_64 headers, and a
    // section_64 is sectname[16], segname[16], addr(8), size(8), offset(4)…
    // Nothing else in the file is decoded — a reader that understood the whole
    // format would be a second Mach-O parser to keep in step with the writer.
    static String* machoIfaceSection(String* path)
        {
        Data* d = Files.readData(path);
        if (d == (Data*)0 || d.length() < (u32)32)
            return (String*)0;
        // MH_MAGIC_64, little-endian: CF FA ED FE
        if (d.byteAt((u32)0) != (u8)$CF || d.byteAt((u32)1) != (u8)$FA || d.byteAt((u32)2) != (u8)$ED || d.byteAt((u32)3) != (u8)$FE)
            return (String*)0;
        u32 ncmds = IfaceImport.le32(d, (u32)16);
        u32 at = (u32)32;
        for (u32 c = (u32)0; c < ncmds && at + (u32)8 <= d.length(); c = c + (u32)1)
            {
            u32 cmd = IfaceImport.le32(d, at);
            u32 size = IfaceImport.le32(d, at + (u32)4);
            if (size == (u32)0)
                return (String*)0; // malformed
            // LC_SEGMENT_64
            if (cmd == (u32)$19)
                {
                u32 nsects = IfaceImport.le32(d, at + (u32)64);
                u32 sec = at + (u32)72;
                for (u32 k = (u32)0; k < nsects && sec + (u32)80 <= d.length();
                     k = k + (u32)1)
                    {
                    if (IfaceImport.nameIs(d, sec, "__iface"))
                        {
                        u32 off = IfaceImport.le32(d, sec + (u32)48);
                        u32 len = IfaceImport.le32(d, sec + (u32)40); // size low half
                        if (off + len > d.length())
                            return (String*)0;
                        String* out = new String();
                        for (u32 i = (u32)0; i < len; i = i + (u32)1)
                            out.appendByte(d.byteAt(off + i));
                        return out;
                        }
                    sec = sec + (u32)80;
                    }
                }
            at = at + size;
            }
        return (String*)0;
        }

    // Every name a Mach-O dylib EXPORTS, read out of its dyld export trie.
    // The trie is what dyld itself consults, so it is the honest answer to
    // "does this library provide X" — the symbol table also lists private
    // definitions, and binding against one of those produces a library that
    // links and then cannot be loaded.
    //
    // A node is: terminalSize (ULEB); if non-zero, flags (ULEB) and address
    // (ULEB); then childCount (1 byte); then that many (NUL-terminated edge
    // string, child-offset ULEB) pairs. Names accumulate down the edges.
    static Array* machoExports(String* path)
        {
        Array* out = new Array();
        Data* d = Files.readData(path);
        if (d == (Data*)0 || d.length() < (u32)32)
            return out;
        if (d.byteAt((u32)0) != (u8)$CF || d.byteAt((u32)1) != (u8)$FA || d.byteAt((u32)2) != (u8)$ED || d.byteAt((u32)3) != (u8)$FE)
            return out;
        u32 ncmds = IfaceImport.le32(d, (u32)16);
        u32 at = (u32)32;
        u32 expOff = (u32)0;
        u32 expLen = (u32)0;
        for (u32 c = (u32)0; c < ncmds && at + (u32)8 <= d.length(); c = c + (u32)1)
            {
            u32 cmd = IfaceImport.le32(d, at);
            u32 size = IfaceImport.le32(d, at + (u32)4);
            if (size == (u32)0)
                return out;
            // LC_DYLD_INFO / LC_DYLD_INFO_ONLY carry the trie's extent at the
            // end of their fixed layout.
            if (cmd == (u32)$22 || cmd == (u32)$80000022)
                {
                expOff = IfaceImport.le32(d, at + (u32)40);
                expLen = IfaceImport.le32(d, at + (u32)44);
                }
            // LC_DYLD_EXPORTS_TRIE is what a CURRENT linker emits instead — a
            // linkedit_data_command, so the extent is at +8/+12. Reading only
            // the legacy command meant a clang-built dylib reported NO exports:
            // the import went unclaimed, dyld looked for it in libSystem, and
            // the program died at launch naming a symbol the dylib plainly has.
            // Our own writer emits LC_DYLD_INFO, which is why every test of
            // this path passed while nothing built by clang worked.
            if (cmd == (u32)$80000033)
                {
                expOff = IfaceImport.le32(d, at + (u32)8);
                expLen = IfaceImport.le32(d, at + (u32)12);
                }
            at = at + size;
            }
        if (expLen == (u32)0 || expOff + expLen > d.length())
            return out;
        IfaceImport.walkTrie(d, expOff, expOff, expOff + expLen,
                             String.withCString(""), out, (u32)0);
        return out;
        }

    // `depth` is a recursion guard, not a semantic limit: a malformed trie can
    // point a child back at its parent, and a reader that loops forever on a
    // bad input is worse than one that gives up on it.
    static void walkTrie(Data* d, u32 base, u32 at, u32 end,
                         String* prefix, Array* out, u32 depth)
        {
        if (depth > (u32)64 || at >= end)
            return;
        u32 p = at;
        u32 termSize = (u32)0;
        u32 shift = (u32)0;
        while (p < end)
            {
            u8 b = d.byteAt(p);
            p = p + (u32)1;
            termSize = termSize | (((u32)(b & (u8)$7F)) << shift);
            shift = shift + (u32)7;
            if ((b & (u8)$80) == (u8)0)
                break;
            }
        if (termSize > (u32)0)
            {
            out.add((Object*)String.withString(prefix));
            p = p + termSize;
            }
        if (p >= end)
            return;
        u32 kids = (u32)d.byteAt(p);
        p = p + (u32)1;
        for (u32 k = (u32)0; k < kids && p < end; k = k + (u32)1)
            {
            String* edge = String.withString(prefix);
            while (p < end && d.byteAt(p) != (u8)0)
                {
                edge.appendByte(d.byteAt(p));
                p = p + (u32)1;
                }
            p = p + (u32)1; // the NUL
            u32 kidOff = (u32)0;
            u32 ksh = (u32)0;
            while (p < end)
                {
                u8 b = d.byteAt(p);
                p = p + (u32)1;
                kidOff = kidOff | (((u32)(b & (u8)$7F)) << ksh);
                ksh = ksh + (u32)7;
                if ((b & (u8)$80) == (u8)0)
                    break;
                }
            IfaceImport.walkTrie(d, base, base + kidOff, end, edge, out, depth + (u32)1);
            }
        }

    static u32 le32(Data* d, u32 at)
        {
        return (u32)d.byteAt(at) | ((u32)d.byteAt(at + (u32)1) << (u32)8) | ((u32)d.byteAt(at + (u32)2) << (u32)16) | ((u32)d.byteAt(at + (u32)3) << (u32)24);
        }

    // A fixed-width, NUL-padded 16-byte name field equals `want`.
    static bool nameIs(Data* d, u32 at, string want)
        {
        String* w = String.withCString(want);
        if (w.byteLength() > (u32)16)
            return false;
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            {
            u8 have = d.byteAt(at + i);
            u8 expect = i < w.byteLength() ? w.byteAt(i) : (u8)0;
            if (have != expect)
                return false;
            }
        return true;
        }

    // The `.xtc.iface` SECTION of an ELF shared object — the ELF analogue of
    // the wasm custom section and the Mach-O `__XTC,__iface`. Section headers
    // only: our own writer emits them for readers like this one.
    static String* elfIfaceSection(String* path)
        {
        Data* d = Files.readData(path);
        if (d == (Data*)0 || d.length() < (u32)64)
            return (String*)0;
        if (d.byteAt((u32)0) != (u8)$7F || d.byteAt((u32)1) != (u8)'E' || d.byteAt((u32)2) != (u8)'L' || d.byteAt((u32)3) != (u8)'F')
            return (String*)0;
        // ELF32 or ELF64 — EI_CLASS says which, and EVERY offset below moves.
        // This read only 64-bit layouts, so an arm9 `.so` (ELF32) was parsed
        // with 64-bit offsets: e_shoff came out of the middle of e_entry, and
        // the section walk found nothing. `#import <GEM>` then reported
        // "cannot read interface" for a file that is present and correct, and
        // the arm9 umbrella library could not be built at all.
        bool elf32 = d.byteAt((u32)4) == (u8)1;
        u32 shoff = elf32 ? IfaceImport.le32(d, (u32)32) : IfaceImport.le32(d, (u32)40);
        u32 shentsize = elf32 ? IfaceImport.le16(d, (u32)46) : IfaceImport.le16(d, (u32)58);
        u32 shnum = elf32 ? IfaceImport.le16(d, (u32)48) : IfaceImport.le16(d, (u32)60);
        u32 shstrndx = elf32 ? IfaceImport.le16(d, (u32)50) : IfaceImport.le16(d, (u32)62);
        // sh_offset and sh_size within a section header: 32-bit words at 16/20
        // in ELF32, 64-bit at 24/32 in ELF64.
        u32 shOffField = elf32 ? (u32)16 : (u32)24;
        u32 shSizeField = elf32 ? (u32)20 : (u32)32;
        if (shnum == (u32)0 || shstrndx >= shnum)
            return (String*)0;
        if (shoff + shnum * shentsize > d.length())
            return (String*)0;
        u32 sh = shoff + shstrndx * shentsize;
        u32 nameBase = IfaceImport.le32(d, sh + shOffField);
        for (u32 i = (u32)0; i < shnum; i = i + (u32)1)
            {
            u32 e = shoff + i * shentsize;
            u32 nameOff = IfaceImport.le32(d, e);
            String* nm = new String();
            u32 k = nameBase + nameOff;
            while (k < d.length() && d.byteAt(k) != (u8)0)
                {
                nm.appendByte(d.byteAt(k));
                k = k + (u32)1;
                }
            if (!nm.equals(String.withCString(".xtc.iface")))
                continue;
            u32 off = IfaceImport.le32(d, e + shOffField);
            u32 len = IfaceImport.le32(d, e + shSizeField);
            if (off + len > d.length())
                return (String*)0;
            String* out = new String();
            for (u32 b = (u32)0; b < len; b = b + (u32)1)
                out.appendByte(d.byteAt(off + b));
            return out;
            }
        return (String*)0;
        }

    static u32 le16(Data* d, u32 at)
        {
        return (u32)d.byteAt(at) | ((u32)d.byteAt(at + (u32)1) << (u32)8);
        }

    static IfaceImport* read(String* path)
        {
        // A `.wasm` LIBRARY carries its interface inside itself, so there is no
        // side file to go missing — read the section rather than the file.
        String* text = (String*)0;
        if (path.hasSuffix(String.withCString(".wasm")))
            text = IfaceImport.wasmIfaceSection(path);
        else if (path.hasSuffix(String.withCString(".dylib")))
            text = IfaceImport.machoIfaceSection(path);
        else if (path.hasSuffix(String.withCString(".so")))
            text = IfaceImport.elfIfaceSection(path);
        else
            text = Files.readText(path);
        if (text == 0)
            return (IfaceImport*)0;
        JsonVal* root = JsonParser.parse(text);
        if (root == 0 || root.kind() != (u8)5)
            return (IfaceImport*)0;
        IfaceImport* im = new IfaceImport();
        im.readClasses(root.member((u8*)"classes"));
        im.readProtocols(root.member((u8*)"protocols"));
        im.readFunctions(root.member((u8*)"functions"));
        im.readSlots(root);
        return im;
        }

    // One method record -> an nkMethodDecl with param kids and NO body.
    Node* methodNode(JsonVal* m)
        {
        Node* md = Node.withName((u16)nkMethodDecl, m.memberStr((u8*)"name"));
        JsonVal* rets = m.member((u8*)"returns");
        String* rt = (rets != 0 && rets.count() > (u32)0)
                         ? rets.at((u32)0).asStr()
                         : String.withCString("void");
        md.setOp(String.withString(rt));
        if (m.memberBool((u8*)"static"))
            md.addFlag((u32)NF_STATIC);
        if (m.memberBool((u8*)"varargs"))
            md.addFlag((u32)NF_VARARGS);
        if (m.memberBool((u8*)"optional"))
            md.addFlag((u32)NF_OPTIONAL);
        if (m.memberBool((u8*)"chain"))
            md.addFlag((u32)NF_CHAINM);
        md.addFlag((u32)NF_EXTERNAL);
        JsonVal* ps = m.member((u8*)"params");
        if (ps != 0)
            {
            for (u32 i = (u32)0; i < ps.count(); i = i + (u32)1)
                {
                JsonVal* p = ps.at(i);
                String* pn = p.memberStr((u8*)"name");
                Node* pd = Node.withName((u16)nkParam,
                                         (pn == 0 || pn.byteLength() == (u32)0) ? String.withCString("-") : pn);
                pd.setOp(String.withString(p.memberStr((u8*)"type")));
                md.add(pd);
                }
            }
        return md;
        }

    void readClasses(JsonVal* cs)
        {
        if (cs == 0)
            return;
        for (u32 i = (u32)0; i < cs.count(); i = i + (u32)1)
            {
            JsonVal* c = cs.at(i);
            Node* cd = Node.withName((u16)nkClassDecl, c.memberStr((u8*)"name"));
            String* parent = c.memberStr((u8*)"parent");
            cd.setOp((parent == 0 || parent.byteLength() == (u32)0)
                         ? String.withCString("-")
                         : String.withString(parent));
            String* protos = String.withCString("");
            JsonVal* pl = c.member((u8*)"protocols");
            if (pl != 0)
                {
                for (u32 j = (u32)0; j < pl.count(); j = j + (u32)1)
                    {
                    if (protos.byteLength() > (u32)0)
                        protos.appendByte((u8)',');
                    protos.append(pl.at(j).asStr());
                    }
                }
            cd.setExtra(protos.byteLength() > (u32)0 ? protos : String.withCString("-"));
            cd.addFlag((u32)NF_EXTERNAL);
            JsonVal* ivs = c.member((u8*)"ivars");
            if (ivs != 0)
                {
                for (u32 j = (u32)0; j < ivs.count(); j = j + (u32)1)
                    {
                    JsonVal* v = ivs.at(j);
                    Node* vd = Node.withName((u16)nkVariableDecl, v.memberStr((u8*)"name"));
                    vd.setOp(String.withString(v.memberStr((u8*)"type")));
                    vd.addFlag((u32)NF_EXTERNAL);
                    cd.add(vd);
                    }
                }
            JsonVal* ms = c.member((u8*)"methods");
            if (ms != 0)
                for (u32 j = (u32)0; j < ms.count(); j = j + (u32)1)
                    cd.add(methodNode(ms.at(j)));
            _decls.add((Object*)cd);
            }
        }

    void readProtocols(JsonVal* ps)
        {
        if (ps == 0)
            return;
        for (u32 i = (u32)0; i < ps.count(); i = i + (u32)1)
            {
            JsonVal* p = ps.at(i);
            Node* pd = Node.withName((u16)nkProtocolDecl, p.memberStr((u8*)"name"));
            pd.addFlag((u32)NF_EXTERNAL);
            JsonVal* ms = p.member((u8*)"methods");
            if (ms != 0)
                for (u32 j = (u32)0; j < ms.count(); j = j + (u32)1)
                    pd.add(methodNode(ms.at(j)));
            _decls.add((Object*)pd);
            }
        }

    void readFunctions(JsonVal* fs)
        {
        if (fs == 0)
            return;
        for (u32 i = (u32)0; i < fs.count(); i = i + (u32)1)
            {
            JsonVal* f = fs.at(i);
            Node* fd = Node.withName((u16)nkFunctionDecl, f.memberStr((u8*)"name"));
            JsonVal* rets = f.member((u8*)"returns");
            String* rt = (rets != 0 && rets.count() > (u32)0)
                             ? rets.at((u32)0).asStr()
                             : String.withCString("void");
            fd.setOp(String.withString(rt));
            if (f.memberBool((u8*)"varargs"))
                fd.addFlag((u32)NF_VARARGS);
            fd.addFlag((u32)NF_EXTERNAL);
            JsonVal* ps = f.member((u8*)"params");
            if (ps != 0)
                {
                for (u32 j = (u32)0; j < ps.count(); j = j + (u32)1)
                    {
                    JsonVal* p = ps.at(j);
                    String* pn = p.memberStr((u8*)"name");
                    Node* pd = Node.withName((u16)nkParam,
                                             (pn == 0 || pn.byteLength() == (u32)0) ? String.withCString("-") : pn);
                    pd.setOp(String.withString(p.memberStr((u8*)"type")));
                    fd.add(pd);
                    }
                }
            _decls.add((Object*)fd);
            }
        }

    void readSlots(JsonVal* root)
        {
        JsonVal* ms = root.member((u8*)"methodSlots");
        if (ms != 0 && ms.kind() == (u8)5)
            {
            for (u32 i = (u32)0; i < ms._keys.count(); i = i + (u32)1)
                {
                JsonVal* v = (JsonVal*)ms._items.get(i);
                _methodSlots.set((Hashable*)(String*)ms._keys.get(i),
                                 (Object*)Number.withU32((u32)v.asNum()));
                }
            }
        // Absent in an interface written before 091 — an older library simply
        // supplies no assumption, which is the pre-fix behaviour and not an
        // error. Nothing here can tell the difference between "no ambient
        // classes" and "written by an older compiler", and neither needs a
        // diagnosis: a client that adopts nothing is exactly where it was.
        JsonVal* as = root.member((u8*)"ambientSlots");
        if (as != 0 && as.kind() == (u8)5)
            {
            for (u32 i = (u32)0; i < as._keys.count(); i = i + (u32)1)
                {
                JsonVal* v = (JsonVal*)as._items.get(i);
                _ambientSlots.set((Hashable*)(String*)as._keys.get(i),
                                  (Object*)Number.withU32((u32)v.asNum()));
                }
            }
        JsonVal* ps = root.member((u8*)"protocolSlots");
        if (ps != 0 && ps.kind() == (u8)5)
            {
            for (u32 i = (u32)0; i < ps._keys.count(); i = i + (u32)1)
                {
                JsonVal* pv = (JsonVal*)ps._items.get(i);
                Map* inner = new Map();
                if (pv.kind() == (u8)5)
                    {
                    for (u32 j = (u32)0; j < pv._keys.count(); j = j + (u32)1)
                        {
                        JsonVal* v = (JsonVal*)pv._items.get(j);
                        inner.set((Hashable*)(String*)pv._keys.get(j),
                                  (Object*)Number.withU32((u32)v.asNum()));
                        }
                    }
                _protoSlots.set((Hashable*)(String*)ps._keys.get(i), (Object*)inner);
                }
            }
        }
    }
