// Dwarf.xc — a C library describes itself; this reads that description.
// =================================================================
//
// `#import <GEM>` against a library THIS compiler did not build has no
// `.xtc.iface` to read: a C library carries its interface in DWARF, and that
// is where the types have to come from. UXKit's binding header says so in as
// many words — "the TYPES (OBJECT, theme, gfx_surface, os_fbinfo) all come
// through #import verbatim, which is what makes this safe" — next to the note
// that a hand-guessed `sizeof(theme)` would have smashed the heap, because it
// is 19502 bytes.
//
// The port had no reader at all, so `OBJECT` was an unknown type name,
// `(OBJECT*)malloc(...)` parsed as an expression, and UXKit's umbrella library
// could not be built by the shipped compiler (uxkit bug 034-D).
//
// THE CARDINAL RULE (library-imports.md §3): a struct layout is taken VERBATIM
// from the DWARF — DW_AT_data_member_location per member, DW_AT_byte_size for
// the whole — and never re-derived by this compiler's own packing. C padding
// is reconstructed as explicit pad fields and the struct is marked `:packed`,
// so tight packing reproduces the C offsets by construction and the natural-
// alignment default can never double-pad an imported layout.
//
// ELF (class 32 and 64, little-endian) and the DWARF 2-5 subset a C compiler
// emits for ordinary declarations. Mach-O/.dSYM is the reference's other half
// and is NOT here yet; `Iface.read` says so rather than pretending.
#import "Foundation.xc"
#import "Files.xc"
#import "Node.xc"

// ── tags, attributes, forms ──────────────────────────────────────────────
#define DW_TAG_array_type $01
#define DW_TAG_enumeration_type $04
#define DW_TAG_formal_parameter $05
#define DW_TAG_member $0D
#define DW_TAG_pointer_type $0F
#define DW_TAG_structure_type $13
#define DW_TAG_subroutine_type $15
#define DW_TAG_typedef $16
#define DW_TAG_union_type $17
#define DW_TAG_unspecified_parameters $18
#define DW_TAG_base_type $24
#define DW_TAG_const_type $26
#define DW_TAG_enumerator $28
#define DW_TAG_subrange_type $21
#define DW_TAG_subprogram $2E
#define DW_TAG_volatile_type $35
#define DW_TAG_restrict_type $37

#define DW_AT_name $03
#define DW_AT_byte_size $0B
#define DW_AT_const_value $1C
#define DW_AT_upper_bound $2F
#define DW_AT_count $37
#define DW_AT_data_member_location $38
#define DW_AT_declaration $3C
#define DW_AT_encoding $3E
#define DW_AT_external $3F
#define DW_AT_type $49
#define DW_AT_linkage_name $6E

#define DW_ATE_boolean $02
#define DW_ATE_float $04
#define DW_ATE_signed $05
#define DW_ATE_signed_char $06
#define DW_ATE_unsigned $07
#define DW_ATE_unsigned_char $08
#define DW_OP_plus_uconst $23

// A byte cursor over one section. `ok` clears on the first out-of-bounds read
// and never comes back: a desynced DWARF walk that keeps going invents types.
class DwCur
    {
    Data* _d;
    u32 _pos;
    u32 _base;
    u32 _end;
    bool _ok;

    void init(void)
        {
        _pos = (u32)0;
        _base = (u32)0;
        _end = (u32)0;
        _ok = false;
        }

    static DwCur* over(Data* d, u32 base, u32 size)
        {
        DwCur* c = new DwCur();
        c._d = d;
        c._base = base;
        c._pos = base;
        c._end = base + size;
        c._ok = d != (Data*)0 && base + size <= d.length();
        if (!c._ok)
            {
            c._base = (u32)0;
            c._pos = (u32)0;
            c._end = (u32)0;
            }
        return c;
        }

    bool ok(void)
        {
        return _ok;
        }
    bool valid(void)
        {
        return _ok && _end > _base;
        }
    u32 pos(void)
        {
        return _pos;
        }
    u32 base(void)
        {
        return _base;
        }
    u32 end(void)
        {
        return _end;
        }
    void seek(u32 p)
        {
        _pos = p;
        }
    void seekRel(u32 o)
        {
        _pos = _base + o;
        }
    bool atEnd(void)
        {
        return _pos >= _end;
        }
    void fail(void)
        {
        _ok = false;
        }

    bool has(u32 n)
        {
        return _ok && _pos + n <= _end;
        }

    u32 u8v(void)
        {
        if (!has((u32)1))
            {
            _ok = false;
            return (u32)0;
            }
        u32 v = (u32)_d.byteAt(_pos);
        _pos = _pos + (u32)1;
        return v;
        }
    u32 u16v(void)
        {
        u32 a = u8v();
        return a | (u8v() << (u32)8);
        }
    u32 u32v(void)
        {
        u32 a = u16v();
        return a | (u16v() << (u32)16);
        }
    // 64-bit values are read as two words; everything this consumes fits 32
    // bits, so the high word is checked for zero rather than carried.
    u32 u64v(void)
        {
        u32 lo = u32v();
        u32 hi = u32v();
        if (hi != (u32)0)
            _ok = false;
        return lo;
        }
    u32 nv(u32 n)
        {
        u32 v = (u32)0;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            v = v | (u8v() << ((u32)8 * i));
        return v;
        }
    u32 uleb(void)
        {
        u32 v = (u32)0;
        u32 shift = (u32)0;
        while (_ok)
            {
            u32 b = u8v();
            v = v | ((b & (u32)$7F) << shift);
            if ((b & (u32)$80) == (u32)0)
                break;
            shift = shift + (u32)7;
            if (shift > (u32)28)
                break;
            }
        return v;
        }
    i32 sleb(void)
        {
        i32 v = (i32)0;
        u32 shift = (u32)0;
        u32 b = (u32)0;
        while (_ok)
            {
            b = u8v();
            v = v | (i32)((b & (u32)$7F) << shift);
            shift = shift + (u32)7;
            if ((b & (u32)$80) == (u32)0)
                break;
            if (shift > (u32)28)
                break;
            }
        // Sign-extend from the last continuation bit.
        if (shift < (u32)32 && (b & (u32)$40) != (u32)0)
            v = v | (i32)(~(u32)0 << shift);
        return v;
        }
    void skip(u32 n)
        {
        if (!has(n))
            {
            _ok = false;
            return;
            }
        _pos = _pos + n;
        }
    }

    // One abbreviation: a tag, a has-children flag, and a flat (attr, form,
    // implicitConst) triple list.
    class DwAbbrev
    {
    u32 _tag;
    bool _hasChildren;
    Array* _attrs;
    void init(void)
        {
        _tag = (u32)0;
        _hasChildren = false;
        _attrs = new Array();
        }
    u32 tag(void)
        {
        return _tag;
        }
    void setTag(u32 t)
        {
        _tag = t;
        }
    bool hasChildren(void)
        {
        return _hasChildren;
        }
    void setHasChildren(bool b)
        {
        _hasChildren = b;
        }
    Array* attrs(void)
        {
        return _attrs;
        }
    }

    // A parsed DIE. Only the attributes this reader consumes are retained;
    // everything else is read purely to keep the cursor aligned.
    class DwDIE
    {
    u32 _offset;
    u32 _tag;
    String* _name;
    String* _linkageName;
    bool _hasType;
    u32 _typeRef;
    bool _hasByteSize;
    u32 _byteSize;
    u32 _encoding;
    bool _hasMemberLoc;
    u32 _memberLoc;
    bool _hasConstValue;
    i32 _constValue;
    bool _hasCount;
    u32 _count;
    bool _external;
    bool _declaration;
    Array* _children;

    void init(void)
        {
        _offset = (u32)0;
        _tag = (u32)0;
        _hasType = false;
        _typeRef = (u32)0;
        _hasByteSize = false;
        _byteSize = (u32)0;
        _encoding = (u32)0;
        _hasMemberLoc = false;
        _memberLoc = (u32)0;
        _hasConstValue = false;
        _constValue = (i32)0;
        _hasCount = false;
        _count = (u32)0;
        _external = false;
        _declaration = false;
        _children = new Array();
        }

    u32 offset(void)
        {
        return _offset;
        }
    void setOffset(u32 v)
        {
        _offset = v;
        }
    u32 tag(void)
        {
        return _tag;
        }
    void setTag(u32 v)
        {
        _tag = v;
        }
    String* name(void)
        {
        return _name;
        }
    void setName(String* s)
        {
        _name = s;
        }
    String* linkageName(void)
        {
        return _linkageName;
        }
    void setLinkageName(String* s)
        {
        _linkageName = s;
        }
    bool hasType(void)
        {
        return _hasType;
        }
    u32 typeRef(void)
        {
        return _typeRef;
        }
    void setTypeRef(u32 v)
        {
        _hasType = true;
        _typeRef = v;
        }
    bool hasByteSize(void)
        {
        return _hasByteSize;
        }
    u32 byteSize(void)
        {
        return _byteSize;
        }
    void setByteSize(u32 v)
        {
        _hasByteSize = true;
        _byteSize = v;
        }
    u32 encoding(void)
        {
        return _encoding;
        }
    void setEncoding(u32 v)
        {
        _encoding = v;
        }
    bool hasMemberLoc(void)
        {
        return _hasMemberLoc;
        }
    u32 memberLoc(void)
        {
        return _memberLoc;
        }
    void setMemberLoc(u32 v)
        {
        if (!_hasMemberLoc)
            {
            _hasMemberLoc = true;
            _memberLoc = v;
            }
        }
    bool hasConstValue(void)
        {
        return _hasConstValue;
        }
    i32 constValue(void)
        {
        return _constValue;
        }
    void setConstValue(i32 v)
        {
        _hasConstValue = true;
        _constValue = v;
        }
    bool hasCount(void)
        {
        return _hasCount;
        }
    u32 count(void)
        {
        return _count;
        }
    void setCount(u32 v)
        {
        _hasCount = true;
        _count = v;
        }
    bool external(void)
        {
        return _external;
        }
    void setExternal(bool b)
        {
        _external = b;
        }
    bool declaration(void)
        {
        return _declaration;
        }
    void setDeclaration(bool b)
        {
        _declaration = b;
        }
    Array* children(void)
        {
        return _children;
        }
    }

    // ── the reader ───────────────────────────────────────────────────────────
    class Dwarf
    {
    Data* _d;
    bool _elf32;
    u32 _ptrWidth;     // the TARGET's pointer width — pad maths needs it
    Map* _sections;    // name -> Array[off, size]
    Map* _dieByOffset; // Number(offset) -> DwDIE
    Map* _typeCache;   // Number(offset) -> String (a type spelling)
    Map* _inProgress;  // cycle guard
    Array* _decls;     // the reconstructed declarations, in discovery order
    Map* _emitted;     // name -> 1, so a type is declared once
    Array* _dieOrder;  // offsets, in the order the walk found them
    DwCur* _info;
    DwCur* _abbrev;
    DwCur* _str;
    DwCur* _lineStr;
    DwCur* _strOffsets;
    String* _soname;
    Map* _exports;

    void init(void)
        {
        _elf32 = false;
        _ptrWidth = (u32)4;
        _sections = new Map();
        _dieByOffset = new Map();
        _typeCache = new Map();
        _inProgress = new Map();
        _decls = new Array();
        _emitted = new Map();
        _dieOrder = new Array();
        _exports = new Map();
        }

    Array* decls(void)
        {
        return _decls;
        }
    String* soname(void)
        {
        return _soname;
        }

    // Read a shared library's self-description. Returns false when the file is
    // not an ELF this reader understands; an ELF with NO DWARF is a success
    // with nothing to declare — a stripped library is still a valid library.
    bool read(String* path, u32 ptrWidth)
        {
        _ptrWidth = ptrWidth == (u32)0 ? (u32)4 : ptrWidth;
        _d = Files.readData(path);
        if (_d == (Data*)0 || _d.length() < (u32)32)
            return false;

        // Dispatch on the container magic. ELF and Mach-O funnel into the same
        // section map and the same DWARF walk; only the front matter — section
        // table, export list, soname — differs.
        if (_d.byteAt((u32)0) == (u8)$7F && _d.byteAt((u32)1) == (u8)'E' && _d.byteAt((u32)2) == (u8)'L' && _d.byteAt((u32)3) == (u8)'F')
            {
            if (_d.length() < (u32)64)
                return false;
            if (_d.byteAt((u32)5) != (u8)1)
                return false; // big-endian: not ours
            _elf32 = _d.byteAt((u32)4) == (u8)1;
            if (!parseElf())
                return false;
            _soname = readSoname(path.lastPathComponent());
            readDynsymExports();
            }
        else if (looksLikeMachO())
            {
            _elf32 = false; // 64-bit throughout
            if (!parseMachO())
                return false;
            _soname = path.lastPathComponent(); // Mach-O has no DT_SONAME
            readMachOExports();
            // A shipped dylib usually carries no DWARF at all: Darwin's linker
            // leaves it in the object files plus a debug map, and dsymutil
            // gathers it into a sibling `.dSYM`. Without this, every macOS
            // `#import <lib>` reads a library with no types — which looks
            // exactly like a library that has none.
            if (_sections.get((Hashable*)String.withCString(".debug_info")) == (Object*)0)
                {
                String* dsym = dsymPathFor(path);
                if (dsym != (String*)0)
                    {
                    Data* dd = Files.readData(dsym);
                    if (dd != (Data*)0 && dd.length() >= (u32)32)
                        {
                        _d = dd;
                        _sections = new Map();
                        parseMachO(); // the dSYM's __DWARF
                        }
                    }
                }
            }
        else
            {
            return false; // neither container
            }

        if (_sections.get((Hashable*)String.withCString(".debug_info")) == (Object*)0)
            return true; // no DWARF: names only
        setupCursors();
        parseAllCompilationUnits();
        buildDeclarations();
        return true;
        }

    // ── ELF section table ────────────────────────────────────────────────
    bool parseElf(void)
        {
        DwCur* c = DwCur.over(_d, (u32)0, _d.length());
        u32 shoff = (u32)0;
        u32 shentsize = (u32)0;
        u32 shnum = (u32)0;
        u32 shstrndx = (u32)0;
        if (_elf32)
            {
            c.seek((u32)$20);
            shoff = c.u32v();
            c.seek((u32)$2E);
            shentsize = c.u16v();
            shnum = c.u16v();
            shstrndx = c.u16v();
            }
        else
            {
            c.seek((u32)$28);
            shoff = c.u64v();
            c.seek((u32)$3A);
            shentsize = c.u16v();
            shnum = c.u16v();
            shstrndx = c.u16v();
            }
        if (!c.ok() || shoff == (u32)0 || shnum == (u32)0)
            return false;
        if (shoff + shentsize * shnum > _d.length())
            return false;
        if (shstrndx >= shnum)
            return false;

        // The string table first — every other name is read through it.
        u32 se = shoff + shstrndx * shentsize;
        u32 strOff = (u32)0;
        u32 strSize = (u32)0;
        DwCur* s = DwCur.over(_d, (u32)0, _d.length());
        s.seek(se + (u32)4); // past sh_name
        if (_elf32)
            {
            s.skip((u32)12);
            strOff = s.u32v();
            strSize = s.u32v();
            }
        else
            {
            s.skip((u32)20);
            strOff = s.u64v();
            strSize = s.u64v();
            }
        if (!s.ok() || strOff + strSize > _d.length())
            return false;

        for (u32 i = (u32)0; i < shnum; i = i + (u32)1)
            {
            DwCur* r = DwCur.over(_d, (u32)0, _d.length());
            r.seek(shoff + i * shentsize);
            u32 nameIdx = r.u32v();
            u32 off = (u32)0;
            u32 size = (u32)0;
            if (_elf32)
                {
                r.skip((u32)12);
                off = r.u32v();
                size = r.u32v();
                }
            else
                {
                r.skip((u32)20);
                off = r.u64v();
                size = r.u64v();
                }
            if (!r.ok())
                continue;
            String* nm = cStringAt(strOff + nameIdx, strOff + strSize);
            if (nm.byteLength() == (u32)0)
                continue;
            Array* rec = new Array();
            rec.add((Object*)Number.withU32(off));
            rec.add((Object*)Number.withU32(size));
            _sections.set((Hashable*)nm, (Object*)rec);
            }
        return true;
        }

    String* cStringAt(u32 off, u32 limit)
        {
        String* out = new String();
        if (_d == (Data*)0 || off >= _d.length() || off >= limit)
            return out;
        u32 cap = limit < _d.length() ? limit : _d.length();
        u32 e = off;
        while (e < cap && _d.byteAt(e) != (u8)0)
            {
            out.appendByte(_d.byteAt(e));
            e = e + (u32)1;
            }
        return out;
        }

    Array* section(string name)
        {
        Object* o = _sections.get((Hashable*)String.withCString(name));
        return o == (Object*)0 ? (Array*)0 : (Array*)o;
        }

    // DT_SONAME is what a client's DT_NEEDED must name; without one the file's
    // own base name is the honest answer.
    String* readSoname(String* fallback)
        {
        Array* dyn = section("dynamic");
        dyn = section(".dynamic");
        Array* dynstr = section(".dynstr");
        if (dyn == (Array*)0 || dynstr == (Array*)0)
            return fallback;
        u32 off = ((Number*)dyn.get((u32)0)).asU32();
        u32 size = ((Number*)dyn.get((u32)1)).asU32();
        u32 strOff = ((Number*)dynstr.get((u32)0)).asU32();
        u32 strSize = ((Number*)dynstr.get((u32)1)).asU32();
        DwCur* c = DwCur.over(_d, off, size);
        u32 w = _elf32 ? (u32)4 : (u32)8;
        while (c.ok() && c.pos() + (u32)2 * w <= c.end())
            {
            u32 tag = _elf32 ? c.u32v() : c.u64v();
            u32 val = _elf32 ? c.u32v() : c.u64v();
            if (tag == (u32)0)
                break; // DT_NULL
            // DT_SONAME
            if (tag == (u32)14)
                {
                String* s = cStringAt(strOff + val, strOff + strSize);
                if (s.byteLength() > (u32)0)
                    return s;
                }
            }
        return fallback;
        }

    // The DEFINED global/weak function and object symbols: what a client can
    // actually link against. An undefined entry is an import, not an export.
    void readDynsymExports(void)
        {
        Array* sym = section(".dynsym");
        Array* strs = section(".dynstr");
        if (sym == (Array*)0 || strs == (Array*)0)
            return;
        u32 off = ((Number*)sym.get((u32)0)).asU32();
        u32 size = ((Number*)sym.get((u32)1)).asU32();
        u32 strOff = ((Number*)strs.get((u32)0)).asU32();
        u32 strSize = ((Number*)strs.get((u32)1)).asU32();
        u32 symsz = _elf32 ? (u32)16 : (u32)24;
        u32 n = symsz == (u32)0 ? (u32)0 : size / symsz;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            DwCur* s = DwCur.over(_d, (u32)0, _d.length());
            s.seek(off + i * symsz);
            u32 nameIdx = (u32)0;
            u32 info = (u32)0;
            u32 shndx = (u32)0;
            if (_elf32)
                {
                nameIdx = s.u32v();
                s.skip((u32)8);
                info = s.u8v();
                s.skip((u32)1);
                shndx = s.u16v();
                }
            else
                {
                nameIdx = s.u32v();
                info = s.u8v();
                s.skip((u32)1);
                shndx = s.u16v();
                }
            if (!s.ok())
                break;
            if (shndx == (u32)0)
                continue; // SHN_UNDEF: imported
            u32 bind = info >> (u32)4;
            u32 kind = info & (u32)$F;
            if (bind != (u32)1 && bind != (u32)2)
                continue; // GLOBAL, WEAK
            if (kind != (u32)1 && kind != (u32)2)
                continue; // OBJECT, FUNC
            String* nm = cStringAt(strOff + nameIdx, strOff + strSize);
            if (nm.byteLength() > (u32)0)
                _exports.set((Hashable*)nm, (Object*)Number.withU32((u32)1));
            }
        }

    DwCur* cursorFor(string name)
        {
        Array* s = section(name);
        if (s == (Array*)0)
            return DwCur.over((Data*)0, (u32)0, (u32)0);
        return DwCur.over(_d, ((Number*)s.get((u32)0)).asU32(),
                          ((Number*)s.get((u32)1)).asU32());
        }

    void setupCursors(void)
        {
        _info = cursorFor(".debug_info");
        _abbrev = cursorFor(".debug_abbrev");
        _str = cursorFor(".debug_str");
        _lineStr = cursorFor(".debug_line_str");
        _strOffsets = cursorFor(".debug_str_offsets");
        }

    // ── Mach-O ───────────────────────────────────────────────────────────
    bool looksLikeMachO(void)
        {
        if (_d == (Data*)0 || _d.length() < (u32)4)
            return false;
        u32 m = (u32)_d.byteAt((u32)0) | ((u32)_d.byteAt((u32)1) << (u32)8) | ((u32)_d.byteAt((u32)2) << (u32)16) | ((u32)_d.byteAt((u32)3) << (u32)24);
        return m == (u32)$FEEDFACF || m == (u32)$CFFAEDFE;
        }

    // `__debug_info` -> `.debug_info`, so the walker looks one name up whatever
    // the container. Mach-O caps a section name at 16 characters, so
    // `__debug_str_offsets` arrives TRUNCATED as `__debug_str_offs` — without
    // that special case DWARF5's string-index forms resolve to nothing, which
    // is every DW_AT_name on a clang-built dylib.
    static String* normDwarfSectionName(String* raw)
        {
        if (raw.equals(String.withCString("__debug_str_offs")))
            return String.withCString(".debug_str_offsets");
        if (raw.hasPrefix(String.withCString("__")))
            {
            String* o = String.withCString(".");
            o.append(raw.substringFromByte((u32)2));
            return o;
            }
        return raw;
        }

    String* fixedName(u32 at, u32 n)
        {
        String* o = new String();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            if (at + i >= _d.length())
                break;
            u8 c = _d.byteAt(at + i);
            if (c == (u8)0)
                break;
            o.appendByte(c);
            }
        return o;
        }

    u32 _machoSymOff;
    u32 _machoNSyms;
    u32 _machoStrOff;
    u32 _machoStrSize;

    bool parseMachO(void)
        {
        if (_d.length() < (u32)32)
            return false;
        _machoSymOff = (u32)0;
        _machoNSyms = (u32)0;
        _machoStrOff = (u32)0;
        _machoStrSize = (u32)0;
        DwCur* c = DwCur.over(_d, (u32)0, _d.length());
        c.seek((u32)16);
        u32 ncmds = c.u32v();
        u32 lcOff = (u32)32; // past the 32-byte mach_header_64
        for (u32 i = (u32)0; i < ncmds; i = i + (u32)1)
            {
            if (lcOff + (u32)8 > _d.length())
                break;
            DwCur* lc = DwCur.over(_d, (u32)0, _d.length());
            lc.seek(lcOff);
            u32 cmd = lc.u32v();
            u32 cmdsize = lc.u32v();
            if (cmdsize < (u32)8 || lcOff + cmdsize > _d.length())
                break;
            // LC_SEGMENT_64
            if (cmd == (u32)$19)
                {
                String* seg = fixedName(lcOff + (u32)8, (u32)16);
                // segment_command_64: cmd, cmdsize, segname[16], 4x u64, 2x u32,
                // then nsects.
                DwCur* sc = DwCur.over(_d, (u32)0, _d.length());
                sc.seek(lcOff + (u32)8 + (u32)16 + (u32)4 * (u32)8 + (u32)2 * (u32)4);
                u32 nsects = sc.u32v();
                if (seg.equals(String.withCString("__DWARF")))
                    {
                    u32 secBase = lcOff + (u32)72; // sections follow the 72-byte cmd
                    for (u32 k = (u32)0; k < nsects; k = k + (u32)1)
                        {
                        u32 rec = secBase + k * (u32)80; // section_64 is 80 bytes
                        if (rec + (u32)80 > _d.length())
                            break;
                        String* sect = fixedName(rec, (u32)16);
                        DwCur* f = DwCur.over(_d, (u32)0, _d.length());
                        f.seek(rec + (u32)32); // past sectname+segname
                        f.u64v();              // addr
                        u32 size = f.u64v();
                        u32 off = f.u32v();
                        Array* r = new Array();
                        r.add((Object*)Number.withU32(off));
                        r.add((Object*)Number.withU32(size));
                        _sections.set((Hashable*)Dwarf.normDwarfSectionName(sect), (Object*)r);
                        }
                    }
                }
            // LC_SYMTAB
            else if (cmd == (u32)$02)
                {
                _machoSymOff = lc.u32v();
                _machoNSyms = lc.u32v();
                _machoStrOff = lc.u32v();
                _machoStrSize = lc.u32v();
                }
            lcOff = lcOff + cmdsize;
            }
        return true;
        }

    // Defined, exported symbols from LC_SYMTAB. Mach-O prefixes a C symbol with
    // an underscore (`_foo`); strip it so the name matches the DWARF
    // DW_AT_name (`foo`) the subprogram walk keys on.
    void readMachOExports(void)
        {
        for (u32 i = (u32)0; i < _machoNSyms; i = i + (u32)1)
            {
            u32 base = _machoSymOff + i * (u32)16; // nlist_64
            if (base + (u32)16 > _d.length())
                break;
            DwCur* s = DwCur.over(_d, (u32)0, _d.length());
            s.seek(base);
            u32 strx = s.u32v();
            u32 ntype = s.u8v();
            if (!s.ok())
                break;
            if ((ntype & (u32)$E0) != (u32)0)
                continue; // N_STAB: a debug-map entry
            if ((ntype & (u32)$01) == (u32)0)
                continue; // not N_EXT
            if ((ntype & (u32)$0E) != (u32)$0E)
                continue; // not N_SECT
            String* nm = cStringAt(_machoStrOff + strx, _machoStrOff + _machoStrSize);
            if (nm.hasPrefix(String.withCString("_")))
                nm = nm.substringFromByte((u32)1);
            if (nm.byteLength() > (u32)0)
                _exports.set((Hashable*)nm, (Object*)Number.withU32((u32)1));
            }
        }

    // `foo.dylib` -> `foo.dylib.dSYM/Contents/Resources/DWARF/foo.dylib`.
    String* dsymPathFor(String* path)
        {
        String* p = String.withString(path);
        p.appendCString(".dSYM/Contents/Resources/DWARF/");
        p.append(path.lastPathComponent());
        return Files.exists(p) ? p : (String*)0;
        }

    // ── DWARF walk ───────────────────────────────────────────────────────
    String* strAt(DwCur* sec, u32 off)
        {
        String* out = new String();
        if (sec == (DwCur*)0 || !sec.valid())
            return out;
        u32 p = sec.base() + off;
        while (p < sec.end() && _d.byteAt(p) != (u8)0)
            {
            out.appendByte(_d.byteAt(p));
            p = p + (u32)1;
            }
        return out;
        }

    // A DWARF5 DW_FORM_strx index: .debug_str_offsets[idx] is an offset into
    // .debug_str, past that section's 8-byte header.
    String* strxAt(u32 idx)
        {
        if (_strOffsets == (DwCur*)0 || !_strOffsets.valid())
            return new String();
        u32 pos = (u32)8 + idx * (u32)4;
        if (_strOffsets.base() + pos + (u32)4 > _strOffsets.end())
            return new String();
        DwCur* t = DwCur.over(_d, _strOffsets.base(), _strOffsets.end() - _strOffsets.base());
        t.seekRel(pos);
        return strAt(_str, t.u32v());
        }

    Map* parseAbbrevTableAt(u32 abbrevOffset)
        {
        Map* table = new Map();
        if (_abbrev == (DwCur*)0 || !_abbrev.valid())
            return table;
        DwCur* c = DwCur.over(_d, _abbrev.base(), _abbrev.end() - _abbrev.base());
        c.seekRel(abbrevOffset);
        while (c.ok() && !c.atEnd())
            {
            u32 code = c.uleb();
            if (code == (u32)0)
                break; // end of this table
            DwAbbrev* ab = new DwAbbrev();
            ab.setTag(c.uleb());
            ab.setHasChildren(c.u8v() != (u32)0);
            while (c.ok())
                {
                u32 at = c.uleb();
                u32 form = c.uleb();
                i32 implicit = (i32)0;
                if (form == (u32)$21)
                    implicit = c.sleb(); // DW_FORM_implicit_const
                if (at == (u32)0 && form == (u32)0)
                    break;
                ab.attrs().add((Object*)Number.withU32(at));
                ab.attrs().add((Object*)Number.withU32(form));
                ab.attrs().add((Object*)Number.withI32(implicit));
                }
            table.set((Hashable*)Number.withU32(code), (Object*)ab);
            }
        return table;
        }

    void parseAllCompilationUnits(void)
        {
        if (_info == (DwCur*)0 || !_info.valid())
            return;
        DwCur* c = DwCur.over(_d, _info.base(), _info.end() - _info.base());
        while (c.ok() && c.pos() + (u32)4 <= c.end())
            {
            u32 cuStart = c.pos() - c.base();
            u32 unitLen = c.u32v();
            if (unitLen == (u32)$FFFF_FFFF)
                break; // 64-bit DWARF: not ours
            u32 cuEnd = c.pos() + unitLen;
            if (cuEnd > c.end())
                cuEnd = c.end();
            u32 version = c.u16v();
            u32 abbrevOff = (u32)0;
            u32 addrSize = (u32)4;
            if (version >= (u32)5)
                {
                c.u8v(); // unit_type
                addrSize = c.u8v();
                abbrevOff = c.u32v();
                }
            else
                {
                abbrevOff = c.u32v();
                addrSize = c.u8v();
                }
            Map* abbrev = parseAbbrevTableAt(abbrevOff);
            DwCur* d = DwCur.over(_d, c.base(), cuEnd - c.base());
            d.seek(c.pos());
            walkDIEs((DwDIE*)0, d, cuStart, addrSize, version, abbrev, (u32)0);
            c.seek(cuEnd);
            }
        }

    // One sibling chain. Returns at the null DIE that ends it. The depth cap is
    // a backstop: a malformed abbrev table can describe a chain that never
    // terminates, and recursing on it would take the compiler down rather than
    // report a bad file.
    void walkDIEs(DwDIE* parent, DwCur* c, u32 cuStart, u32 addrSize,
                  u32 version, Map* abbrev, u32 depth)
        {
        if (depth > (u32)64)
            {
            c.fail();
            return;
            }
        while (c.ok() && !c.atEnd())
            {
            u32 dieOff = c.pos() - c.base();
            u32 code = c.uleb();
            if (code == (u32)0)
                return; // end of sibling chain
            Object* abo = abbrev.get((Hashable*)Number.withU32(code));
            if (abo == (Object*)0)
                {
                c.fail();
                return;
                }
            DwAbbrev* ab = (DwAbbrev*)abo;

            DwDIE* die = new DwDIE();
            die.setOffset(dieOff);
            die.setTag(ab.tag());
            _dieByOffset.set((Hashable*)Number.withU32(dieOff), (Object*)die);
            _dieOrder.add((Object*)Number.withU32(dieOff));

            Array* at = ab.attrs();
            for (u32 i = (u32)0; i + (u32)2 < at.count(); i = i + (u32)3)
                {
                readAttr(((Number*)at.get(i)).asU32(),
                         ((Number*)at.get(i + (u32)1)).asU32(),
                         ((Number*)at.get(i + (u32)2)).asI32(),
                         die, c, cuStart, addrSize, version);
                }
            if (parent != (DwDIE*)0)
                parent.children().add((Object*)die);
            if (ab.hasChildren())
                walkDIEs(die, c, cuStart, addrSize, version, abbrev, depth + (u32)1);
            }
        }

    // Decode one attribute by its FORM, advancing the cursor. Attributes this
    // reader does not consume are still READ — skipping them by guess would
    // desync the walk, and a desynced walk invents types rather than failing.
    void readAttr(u32 at, u32 form, i32 implicit, DwDIE* die, DwCur* c,
                  u32 cuStart, u32 addrSize, u32 version)
        {
        String* strVal = (String*)0;
        bool haveU = false;
        u32 uVal = (u32)0;
        bool haveS = false;
        i32 sVal = (i32)0;
        bool haveRef = false;
        u32 refVal = (u32)0;
        bool haveFlag = false;
        bool flagVal = false;

        if (form == (u32)$01)
            {
            uVal = c.nv(addrSize == (u32)0 ? (u32)4 : addrSize);
            haveU = true;
            }
        else if (form == (u32)$0B)
            {
            uVal = c.u8v();
            haveU = true;
            }
        else if (form == (u32)$05)
            {
            uVal = c.u16v();
            haveU = true;
            }
        else if (form == (u32)$06)
            {
            uVal = c.u32v();
            haveU = true;
            }
        else if (form == (u32)$07)
            {
            uVal = c.u64v();
            haveU = true;
            }
        // data16
        else if (form == (u32)$1E)
            {
            c.skip((u32)16);
            }
        else if (form == (u32)$0F)
            {
            uVal = c.uleb();
            haveU = true;
            }
        else if (form == (u32)$0D)
            {
            sVal = c.sleb();
            haveS = true;
            }
        // sec_offset
        else if (form == (u32)$17)
            {
            uVal = c.u32v();
            haveU = true;
            }
        // strp
        else if (form == (u32)$0E)
            {
            strVal = strAt(_str, c.u32v());
            }
        // line_strp
        else if (form == (u32)$1F)
            {
            strVal = strAt(_lineStr, c.u32v());
            }
        // string
        else if (form == (u32)$08)
            {
            String* s = new String();
            while (c.ok() && !c.atEnd())
                {
                u32 b = c.u8v();
                if (b == (u32)0)
                    break;
                s.appendByte((u8)b);
                }
            strVal = s;
            }
        else if (form == (u32)$0C)
            {
            flagVal = c.u8v() != (u32)0;
            haveFlag = true;
            }
        // flag_present
        else if (form == (u32)$19)
            {
            flagVal = true;
            haveFlag = true;
            }
        else if (form == (u32)$11)
            {
            refVal = cuStart + c.u8v();
            haveRef = true;
            }
        else if (form == (u32)$12)
            {
            refVal = cuStart + c.u16v();
            haveRef = true;
            }
        else if (form == (u32)$13)
            {
            refVal = cuStart + c.u32v();
            haveRef = true;
            }
        else if (form == (u32)$14)
            {
            refVal = cuStart + c.u64v();
            haveRef = true;
            }
        else if (form == (u32)$15)
            {
            refVal = cuStart + c.uleb();
            haveRef = true;
            }
        // ref_addr
        else if (form == (u32)$10)
            {
            refVal = c.u32v();
            haveRef = true;
            }
        // ref_sig8
        else if (form == (u32)$20)
            {
            c.u64v();
            }
        // ref_sup4
        else if (form == (u32)$1C)
            {
            c.u32v();
            }
        // ref_sup8
        else if (form == (u32)$24)
            {
            c.u64v();
            }
        // strp_sup
        else if (form == (u32)$1D)
            {
            c.u32v();
            }
        else if (form == (u32)$18)
            {
            consumeBlock(c, c.uleb(), at == (u32)DW_AT_data_member_location, die);
            }
        else if (form == (u32)$0A)
            {
            consumeBlock(c, c.u8v(), at == (u32)DW_AT_data_member_location, die);
            }
        else if (form == (u32)$03)
            {
            consumeBlock(c, c.u16v(), at == (u32)DW_AT_data_member_location, die);
            }
        else if (form == (u32)$04)
            {
            consumeBlock(c, c.u32v(), at == (u32)DW_AT_data_member_location, die);
            }
        else if (form == (u32)$09)
            {
            consumeBlock(c, c.uleb(), at == (u32)DW_AT_data_member_location, die);
            }
        else if (form == (u32)$21)
            {
            sVal = implicit;
            haveS = true;
            uVal = (u32)implicit;
            haveU = true;
            }
        // strx
        else if (form == (u32)$1A)
            {
            strVal = strxAt(c.uleb());
            }
        else if (form == (u32)$25)
            {
            strVal = strxAt(c.u8v());
            }
        else if (form == (u32)$26)
            {
            strVal = strxAt(c.u16v());
            }
        else if (form == (u32)$27)
            {
            strVal = strxAt(c.nv((u32)3));
            }
        else if (form == (u32)$28)
            {
            strVal = strxAt(c.u32v());
            }
        // addrx1
        else if (form == (u32)$29)
            {
            c.u8v();
            }
        else if (form == (u32)$2A)
            {
            c.u16v();
            }
        else if (form == (u32)$2B)
            {
            c.nv((u32)3);
            }
        else if (form == (u32)$2C)
            {
            c.u32v();
            }
        else if (form == (u32)$1B || form == (u32)$22 || form == (u32)$23)
            {
            c.uleb();
            }
        // indirect
        else if (form == (u32)$16)
            {
            readAttr(at, c.uleb(), (i32)0, die, c, cuStart, addrSize, version);
            return;
            }
        // an unknown form: stop, don't desync
        else
            {
            c.fail();
            return;
            }

        if (at == (u32)DW_AT_name)
            {
            if (strVal != (String*)0)
                die.setName(strVal);
            }
        else if (at == (u32)DW_AT_linkage_name)
            {
            if (strVal != (String*)0)
                die.setLinkageName(strVal);
            }
        else if (at == (u32)DW_AT_type)
            {
            if (haveRef)
                die.setTypeRef(refVal);
            }
        else if (at == (u32)DW_AT_byte_size)
            {
            if (haveU)
                die.setByteSize(uVal);
            }
        else if (at == (u32)DW_AT_encoding)
            {
            if (haveU)
                die.setEncoding(uVal);
            }
        else if (at == (u32)DW_AT_data_member_location)
            {
            if (haveU)
                die.setMemberLoc(uVal);
            }
        else if (at == (u32)DW_AT_const_value)
            {
            die.setConstValue(haveS ? sVal : (i32)uVal);
            }
        else if (at == (u32)DW_AT_upper_bound)
            {
            if (haveU)
                die.setCount(uVal + (u32)1);
            else if (haveS && sVal >= (i32)0)
                die.setCount((u32)sVal + (u32)1);
            }
        else if (at == (u32)DW_AT_count)
            {
            if (haveU)
                die.setCount(uVal);
            }
        else if (at == (u32)DW_AT_external)
            {
            if (haveFlag)
                die.setExternal(flagVal);
            }
        else if (at == (u32)DW_AT_declaration)
            {
            if (haveFlag)
                die.setDeclaration(flagVal);
            }
        }

    // A location expression. For DW_AT_data_member_location it may be
    // `DW_OP_plus_uconst <off>` — decode that one case to recover the member's
    // byte offset, and skip the rest.
    void consumeBlock(DwCur* c, u32 n, bool isMemberLoc, DwDIE* die)
        {
        if (n == (u32)0)
            return;
        if (!c.has(n))
            {
            c.fail();
            return;
            }
        u32 start = c.pos();
        if (isMemberLoc && !die.hasMemberLoc() && _d.byteAt(start) == (u8)DW_OP_plus_uconst)
            {
            DwCur* b = DwCur.over(_d, start + (u32)1, n - (u32)1);
            die.setMemberLoc(b.uleb());
            }
        c.skip(n);
        }

    // ── DWARF type DIE -> an xtc type SPELLING ───────────────────────────
    //
    // The port's types are spellings, not objects, so a reconstructed struct
    // becomes a `struct` DECLARATION plus a name to refer to it by. The
    // declaration is emitted once, the first time the type is reached.
    DwDIE* dieAt(u32 ref)
        {
        Object* o = _dieByOffset.get((Hashable*)Number.withU32(ref));
        return o == (Object*)0 ? (DwDIE*)0 : (DwDIE*)o;
        }

    String* typeForRef(u32 ref)
        {
        DwDIE* die = dieAt(ref);
        if (die == (DwDIE*)0)
            return (String*)0;
        return typeForDIE(die);
        }

    String* typeForDIE(DwDIE* die)
        {
        Hashable* key = (Hashable*)Number.withU32(die.offset());
        Object* cached = _typeCache.get(key);
        if (cached != (Object*)0)
            return (String*)cached;
        if (_inProgress.get(key) != (Object*)0)
            return (String*)0; // mid-construction

        u32 t = die.tag();
        if (t == (u32)DW_TAG_base_type)
            return mapBaseType(die);
        if (t == (u32)DW_TAG_pointer_type)
            return mapPointerType(die);
        if (t == (u32)DW_TAG_typedef)
            return mapTypedef(die);
        if (t == (u32)DW_TAG_const_type || t == (u32)DW_TAG_volatile_type || t == (u32)DW_TAG_restrict_type)
            return die.hasType() ? typeForRef(die.typeRef()) : String.withCString("void");
        if (t == (u32)DW_TAG_structure_type)
            return mapStructType(die, false);
        if (t == (u32)DW_TAG_union_type)
            return mapStructType(die, true);
        if (t == (u32)DW_TAG_enumeration_type)
            return mapEnumType(die);
        if (t == (u32)DW_TAG_array_type)
            return mapArrayType(die);
        if (t == (u32)DW_TAG_subroutine_type)
            return mapSubroutineType(die);
        return (String*)0;
        }

    String* cache(DwDIE* die, String* ty)
        {
        _typeCache.set((Hashable*)Number.withU32(die.offset()), (Object*)ty);
        return ty;
        }

    String* mapBaseType(DwDIE* die)
        {
        u32 sz = die.hasByteSize() ? die.byteSize() : (u32)0;
        u32 e = die.encoding();
        if (e == (u32)DW_ATE_boolean)
            return cache(die, String.withCString("bool"));
        if (e == (u32)DW_ATE_float)
            return cache(die, String.withCString(sz >= (u32)8 ? "double" : "float"));
        if (e == (u32)DW_ATE_signed || e == (u32)DW_ATE_signed_char)
            {
            if (sz <= (u32)1)
                return cache(die, String.withCString("i8"));
            if (sz == (u32)2)
                return cache(die, String.withCString("i16"));
            if (sz == (u32)8)
                return cache(die, String.withCString("i64"));
            return cache(die, String.withCString("i32"));
            }
        if (sz <= (u32)1)
            return cache(die, String.withCString("u8"));
        if (sz == (u32)2)
            return cache(die, String.withCString("u16"));
        if (sz == (u32)8)
            return cache(die, String.withCString("u64"));
        return cache(die, String.withCString("u32"));
        }

    // Resolve the pointee FIRST and only then cache the pointer. Pre-caching a
    // placeholder loses: `struct node *next` re-enters this same pointer DIE
    // while the struct is still being built, and would capture the placeholder
    // instead of the real `node*`. The cycle is broken in mapStructType, which
    // caches the struct's NAME before resolving its fields — every C recursive
    // type closes through an aggregate, so the pointee lookup lands there.
    String* mapPointerType(DwDIE* die)
        {
        String* pointee = die.hasType() ? typeForRef(die.typeRef()) : String.withCString("void");
        if (pointee == (String*)0)
            return String.withCString("pointer"); // truly opaque
        String* p = String.withString(pointee);
        p.appendByte((u8)'*');
        return cache(die, p);
        }

    // `typedef struct { … } OBJECT;` — in C the typedef name IS the type's
    // name. The struct DIE is anonymous, so it would otherwise be called
    // `$anon_<offset>`, a name no client can resolve.
    String* mapTypedef(DwDIE* die)
        {
        if (!die.hasType())
            return (String*)0;
        DwDIE* under = dieAt(die.typeRef());
        if (under != (DwDIE*)0 && die.name() != (String*)0 && die.name().byteLength() > (u32)0 && (under.tag() == (u32)DW_TAG_structure_type || under.tag() == (u32)DW_TAG_union_type) && (under.name() == (String*)0 || under.name().byteLength() == (u32)0))
            {
            // Name the anonymous aggregate after its typedef, then build it.
            under.setName(die.name());
            }
        String* u = typeForRef(die.typeRef());
        if (u == (String*)0)
            return (String*)0;
        return cache(die, u);
        }

    // The layout is DWARF's, VERBATIM: every member at its recorded offset,
    // the gaps between them reconstructed as explicit pad fields, and the
    // whole marked `:packed` so tight packing reproduces the C offsets exactly.
    // Re-deriving the layout from the field types would be a second opinion,
    // and the two only have to disagree once.
    String* mapStructType(DwDIE* die, bool isUnion)
        {
        String* tag = (die.name() != (String*)0 && die.name().byteLength() > (u32)0)
                          ? String.withString(die.name())
                          : String.withCString("$anon_").appending(String.withU32(die.offset()));
        u32 total = die.hasByteSize() ? die.byteSize() : (u32)0;
        cache(die, tag);

        // A union has no xtc kind: it becomes an opaque blob of the right size,
        // which preserves its own size and every enclosing offset.
        if (isUnion)
            {
            emitOpaque(tag, total);
            return tag;
            }

        _inProgress.set((Hashable*)Number.withU32(die.offset()), (Object*)Number.withU32((u32)1));
        Array* fieldNames = new Array();
        Array* fieldTypes = new Array();
        u32 running = (u32)0;
        u32 padSeq = (u32)0;
        Array* kids = die.children();
        for (u32 i = (u32)0; i < kids.count(); i = i + (u32)1)
            {
            DwDIE* ch = (DwDIE*)kids.get(i);
            if (ch.tag() != (u32)DW_TAG_member || !ch.hasMemberLoc())
                continue;
            u32 off = ch.memberLoc();
            if (off > running)
                {
                addPad(fieldNames, fieldTypes, off - running, padSeq);
                padSeq = padSeq + (u32)1;
                running = off;
                }
            else if (off < running)
                {
                continue; // overlap: trust DWARF, drop it
                }
            String* ft = ch.hasType() ? typeForRef(ch.typeRef()) : String.withCString("u8");
            if (ft == (String*)0)
                ft = String.withCString("pointer");
            String* fname = (ch.name() != (String*)0 && ch.name().byteLength() > (u32)0)
                                ? String.withString(ch.name())
                                : String.withCString("$f").appending(String.withU32(ch.offset()));
            // Cap the field at the span DWARF gives it. A type mapped wider
            // than its slot would eat the next member.
            u32 slot = slotSpanFor(die, off, total);
            u32 w = nativeWidthOf(ft);
            if (slot > (u32)0 && w > slot)
                {
                addPad(fieldNames, fieldTypes, slot, padSeq);
                padSeq = padSeq + (u32)1;
                running = off + slot;
                continue;
                }
            fieldNames.add((Object*)fname);
            fieldTypes.add((Object*)ft);
            running = off + w;
            }
        if (total > running)
            {
            addPad(fieldNames, fieldTypes, total - running, padSeq);
            }
        _inProgress.set((Hashable*)Number.withU32(die.offset()), (Object*)0);
        emitStruct(tag, fieldNames, fieldTypes, total);
        return tag;
        }

    // The span allotted to the member at `off`: to the next member's offset,
    // or to the struct's total for the last one.
    u32 slotSpanFor(DwDIE* die, u32 off, u32 total)
        {
        u32 next = total;
        Array* kids = die.children();
        for (u32 i = (u32)0; i < kids.count(); i = i + (u32)1)
            {
            DwDIE* ch = (DwDIE*)kids.get(i);
            if (ch.tag() != (u32)DW_TAG_member || !ch.hasMemberLoc())
                continue;
            u32 mo = ch.memberLoc();
            if (mo > off && mo < next)
                next = mo;
            }
        return next > off ? next - off : (u32)0;
        }

    // The footprint a field takes in the TARGET's layout. A pointer is the
    // target's pointer width — the back end re-sizes pointers, so the pad
    // arithmetic has to as well or a pointer-then-member struct mis-lays.
    u32 nativeWidthOf(String* t)
        {
        if (t == (String*)0)
            return (u32)1;
        if (t.byteLength() > (u32)0 && t.byteAt(t.byteLength() - (u32)1) == (u8)'*')
            return _ptrWidth;
        // `T[N]` is N of them. Without this an array field advanced the running
        // offset by ONE, so the gap to the next member was re-inserted as pad
        // and the struct came out multiples of its real size — `theme` measured
        // 48943 bytes against the reference's 19500.
        if (t.byteLength() > (u32)0 && t.byteAt(t.byteLength() - (u32)1) == (u8)']')
            {
            u32 open = String.notFound();
            for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
                if (t.byteAt(i) == (u8)'[')
                    {
                    open = i;
                    i = t.byteLength();
                    }
            if (open != String.notFound())
                {
                u32 n = (u32)0;
                for (u32 i = open + (u32)1; i + (u32)1 < t.byteLength(); i = i + (u32)1)
                    {
                    u8 c = t.byteAt(i);
                    if (c < (u8)'0' || c > (u8)'9')
                        {
                        n = (u32)0;
                        i = t.byteLength();
                        }
                    else
                        n = n * (u32)10 + (u32)(c - (u8)'0');
                    }
                u32 ew = nativeWidthOf(t.substringBytes((u32)0, open));
                return n == (u32)0 ? ew : n * ew;
                }
            }
        if (t.equals(String.withCString("pointer")))
            return _ptrWidth;
        if (t.equals(String.withCString("u8")) || t.equals(String.withCString("i8")) || t.equals(String.withCString("bool")))
            return (u32)1;
        if (t.equals(String.withCString("u16")) || t.equals(String.withCString("i16")))
            return (u32)2;
        if (t.equals(String.withCString("u32")) || t.equals(String.withCString("i32")) || t.equals(String.withCString("float")))
            return (u32)4;
        if (t.equals(String.withCString("u64")) || t.equals(String.withCString("i64")) || t.equals(String.withCString("double")))
            return (u32)8;
        // A named aggregate or an array: its own recorded size.
        Object* sz = _emitted.get((Hashable*)t);
        if (sz != (Object*)0)
            return ((Number*)sz).asU32();
        return (u32)1;
        }

    void addPad(Array* names, Array* types, u32 n, u32 seq)
        {
        String* nm = String.withCString("__pad");
        nm.appendFormat("%lu", seq);
        String* ty = String.withCString("u8");
        if (n > (u32)1)
            {
            ty.appendByte((u8)'[');
            ty.appendFormat("%lu", n);
            ty.appendByte((u8)']');
            }
        names.add((Object*)nm);
        types.add((Object*)ty);
        }

    String* mapEnumType(DwDIE* die)
        {
        String* tag = (die.name() != (String*)0 && die.name().byteLength() > (u32)0)
                          ? String.withString(die.name())
                          : String.withCString("$enum_").appending(String.withU32(die.offset()));
        cache(die, tag);
        // The enum's CONSTANTS are emitted whether or not the enum is named:
        // a C header routinely writes `enum { G_BOX = 20, … };`, nothing ever
        // names that type, and its constants are the whole point of it.
        emitEnum(tag, die);
        return tag;
        }

    String* mapArrayType(DwDIE* die)
        {
        String* elem = die.hasType() ? typeForRef(die.typeRef()) : String.withCString("u8");
        if (elem == (String*)0)
            elem = String.withCString("u8");
        u32 count = (u32)0;
        Array* kids = die.children();
        for (u32 i = (u32)0; i < kids.count(); i = i + (u32)1)
            {
            DwDIE* ch = (DwDIE*)kids.get(i);
            if (ch.tag() == (u32)DW_TAG_subrange_type && ch.hasCount())
                {
                count = ch.count();
                break;
                }
            }
        String* t = String.withString(elem);
        t.appendByte((u8)'[');
        if (count > (u32)0)
            t.appendFormat("%lu", count);
        t.appendByte((u8)']');
        return cache(die, t);
        }

    // A function TYPE, which in C is only ever reached through a pointer.
    //
    // It becomes an opaque `pointer` rather than a spelled signature. The
    // reference reconstructs the full type, and that is better where it can be
    // used — but a spelled signature reaching this compiler as a STRUCT FIELD
    // type is not something the rest of it can parse ("unsupported: type
    // i32)"), and inventing a spelling nothing downstream accepts is worse
    // than declaring the truth that this is a pointer.
    //
    // What matters for the CARDINAL RULE is preserved either way: a pointer
    // occupies the target's pointer width, so every enclosing offset still
    // reproduces the DWARF layout exactly. A binding header that wants to CALL
    // through such a field declares the signature itself, which is what
    // UXGem.h.xc does.
    String* mapSubroutineType(DwDIE* die)
        {
        return cache(die, String.withCString("pointer"));
        }

    // ── declaration emission ─────────────────────────────────────────────
    bool alreadyEmitted(String* name)
        {
        if (name == (String*)0 || name.byteLength() == (u32)0)
            return true;
        return _emitted.get((Hashable*)name) != (Object*)0;
        }

    void emitStruct(String* name, Array* fieldNames, Array* fieldTypes, u32 dwarfSize)
        {
        if (alreadyEmitted(name))
            return;
        Node* st = Node.withName((u16)nkStructDecl, name);
        // `:packed` is load-bearing: the offsets arrive as explicit pads, so
        // natural alignment on top of them would double-pad the layout.
        st.addFlag((u32)NF_PACKED);
        st.addFlag((u32)NF_EXTERNAL);
        u32 sum = (u32)0;
        for (u32 i = (u32)0; i < fieldNames.count(); i = i + (u32)1)
            {
            Node* f = Node.withName((u16)nkVariableDecl, (String*)fieldNames.get(i));
            f.setOp((String*)fieldTypes.get(i));
            st.add(f);
            sum = sum + nativeWidthOf((String*)fieldTypes.get(i));
            }
        // The DWARF byte size is the authority — a nested struct's footprint in
        // its PARENT has to be what the library says it is, not what re-adding
        // this compiler's own field widths comes to.
        _emitted.set((Hashable*)name,
                     (Object*)Number.withU32(dwarfSize != (u32)0 ? dwarfSize : sum));
        _decls.add((Object*)st);
        }

    void emitOpaque(String* name, u32 bytes)
        {
        if (alreadyEmitted(name))
            return;
        Array* n = new Array();
        Array* t = new Array();
        if (bytes > (u32)0)
            {
            String* ty = String.withCString("u8[");
            ty.appendFormat("%lu", bytes);
            ty.appendByte((u8)']');
            n.add((Object*)String.withCString("__opaque"));
            t.add((Object*)ty);
            }
        emitStruct(name, n, t, bytes);
        }

    void emitEnum(String* name, DwDIE* die)
        {
        if (alreadyEmitted(name))
            return;
        Node* en = Node.withName((u16)nkEnumDecl, name);
        en.addFlag((u32)NF_EXTERNAL);
        Array* kids = die.children();
        for (u32 i = (u32)0; i < kids.count(); i = i + (u32)1)
            {
            DwDIE* ch = (DwDIE*)kids.get(i);
            if (ch.tag() != (u32)DW_TAG_enumerator)
                continue;
            if (ch.name() == (String*)0 || ch.name().byteLength() == (u32)0)
                continue;
            Node* m = Node.withName((u16)nkEnumMember, String.withString(ch.name()));
            m.setNum((i64)(ch.hasConstValue() ? ch.constValue() : (i32)0));
            m.setOp(String.withCString("v"));
            en.add(m);
            }
        _emitted.set((Hashable*)name, (Object*)Number.withU32((u32)4));
        _decls.add((Object*)en);
        }

    // ── the whole interface ──────────────────────────────────────────────
    //
    // Types first, then the exported functions. A subprogram is only declared
    // when the DYNAMIC SYMBOL TABLE also exports it: DWARF describes static
    // helpers too, and declaring one gives a client a name it cannot link.
    void buildDeclarations(void)
        {
        // Every named aggregate and every enum, whether or not a subprogram
        // signature reaches it — an anonymous enum's constants are reached no
        // other way, and a type a client names must exist even if no exported
        // function mentions it.
        for (u32 i = (u32)0; i < _dieOrder.count(); i = i + (u32)1)
            {
            DwDIE* die = dieAt(((Number*)_dieOrder.get(i)).asU32());
            if (die == (DwDIE*)0)
                continue;
            u32 t = die.tag();
            if (t == (u32)DW_TAG_typedef && die.hasType())
                {
                typeForDIE(die);
                continue;
                }
            if (t == (u32)DW_TAG_enumeration_type)
                {
                typeForDIE(die);
                continue;
                }
            if (t != (u32)DW_TAG_structure_type && t != (u32)DW_TAG_union_type)
                continue;
            if (die.name() == (String*)0 || die.name().byteLength() == (u32)0)
                continue;
            if (die.declaration())
                continue; // a forward declaration
            typeForDIE(die);
            }

        Map* seenFn = new Map();
        for (u32 i = (u32)0; i < _dieOrder.count(); i = i + (u32)1)
            {
            DwDIE* die = dieAt(((Number*)_dieOrder.get(i)).asU32());
            if (die == (DwDIE*)0 || die.tag() != (u32)DW_TAG_subprogram)
                continue;
            String* nm = (die.linkageName() != (String*)0 && die.linkageName().byteLength() > (u32)0)
                             ? die.linkageName()
                             : die.name();
            if (nm == (String*)0 || nm.byteLength() == (u32)0)
                continue;
            if (_exports.get((Hashable*)nm) == (Object*)0)
                continue;
            if (seenFn.get((Hashable*)nm) != (Object*)0)
                continue;
            seenFn.set((Hashable*)nm, (Object*)Number.withU32((u32)1));

            String* ret = die.hasType() ? typeForRef(die.typeRef()) : String.withCString("void");
            if (ret == (String*)0)
                ret = String.withCString("void");
            Node* fd = Node.withName((u16)nkFunctionDecl, String.withString(nm));
            fd.setOp(ret);
            fd.addFlag((u32)NF_EXTERNAL);
            Array* kids = die.children();
            for (u32 k = (u32)0; k < kids.count(); k = k + (u32)1)
                {
                DwDIE* ch = (DwDIE*)kids.get(k);
                if (ch.tag() == (u32)DW_TAG_unspecified_parameters)
                    {
                    fd.addFlag((u32)NF_VARARGS);
                    continue;
                    }
                if (ch.tag() != (u32)DW_TAG_formal_parameter)
                    continue;
                String* pt = ch.hasType() ? typeForRef(ch.typeRef()) : String.withCString("pointer");
                if (pt == (String*)0)
                    pt = String.withCString("pointer");
                String* pn = (ch.name() != (String*)0 && ch.name().byteLength() > (u32)0)
                                 ? String.withString(ch.name())
                                 : String.withCString("-");
                Node* pd = Node.withName((u16)nkParam, pn);
                pd.setOp(pt);
                fd.add(pd);
                }
            _decls.add((Object*)fd);
            }
        }
    }
