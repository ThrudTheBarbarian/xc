// CoffObject.xc — reading a FOREIGN PE/COFF relocatable object.
// =================================================================
//
// The COFF half of private:docs/Design/foreign-object-linking.md. `ElfObject` does this
// for Linux; this does it for win64, so `-A win64` can link against mingw's
// libmingwex.a and libmsvcrt.a without a vendor toolchain.
//
// The output shape is deliberately the SAME as ElfObject's — blobs, per-section
// placement, symbols classified by blob, relocations rebased — so the merge
// downstream is the same algorithm rather than a second one that has to be kept
// in step.
//
// Four things COFF does differently from ELF, each of which is a bug if missed:
//
//   * A symbol's name is INLINE in its 18-byte record when it fits in 8 bytes,
//     and a string-table offset only when the first four bytes are zero.
//   * AUXILIARY records occupy symbol-table slots and relocations index the
//     table by slot, so they must be kept as placeholders. Skipping them
//     renumbers every symbol after the first aux record.
//   * The addend lives IN THE SECTION DATA, not in the relocation, and a REL32
//     carries an implied +4 that has to be undone.
//   * A real object holds MANY code sections — one per COMDAT function is
//     ordinary in a libc — so taking the first leaves most of the member's code
//     out of the image while still claiming its symbols.
#import "Foundation.xc"
#import "ElfObject.xc" // ElfSymDef / ElfReloc: one shape for both formats

#define COFF_MACHINE_AMD64 $8664
#define COFF_SCN_CODE $00000020
#define COFF_SCN_INIT_DATA $00000040
#define COFF_SCN_UNINIT_DATA $00000080
#define COFF_SCN_DISCARDABLE $02000000
#define COFF_SECT_HDR_SIZE 40
#define COFF_SYM_SZ 18
#define COFF_RELOC_SZ 10
#define COFF_REL_ADDR64 $01
#define COFF_REL_REL32 $04

class CoffSection
    {
    String* _name;
    u32 _size;
    u32 _raw;
    u32 _rel;
    u32 _nrel;
    u32 _chars;
    void init(void)
        {
        }
    String* name(void)
        {
        return _name;
        }
    u32 size(void)
        {
        return _size;
        }
    u32 raw(void)
        {
        return _raw;
        }
    u32 rel(void)
        {
        return _rel;
        }
    u32 nrel(void)
        {
        return _nrel;
        }
    u32 chars(void)
        {
        return _chars;
        }
    bool isCode(void)
        {
        return (_chars & (u32)COFF_SCN_CODE) != (u32)0;
        }
    // Sections a real toolchain's objects carry that a linker like ours must
    // NOT take. Measured against mingw's libmingwex.a + libmsvcrt.a: every
    // SECREL relocation lives in a DISCARDABLE section (the DWARF .debug_*
    // group, which COFF names `/<offset>`), and every ADDR32NB lives in .idata
    // or .pdata. Dropping these is not a shortcut — it is what makes those two
    // relocation types unreachable, so the reader needs neither.
    //
    //   .idata  a DLL import descriptor. We build our own from the import map,
    //           so mingw's would be a second, conflicting one.
    //   .pdata  SEH unwind info, .xdata its payload. Nothing we emit unwinds.
    bool skippable(void)
        {
        if ((_chars & (u32)COFF_SCN_DISCARDABLE) != (u32)0)
            return true;
        return _name.hasPrefix(String.withCString(".idata")) || _name.hasPrefix(String.withCString(".pdata")) || _name.hasPrefix(String.withCString(".xdata")) || _name.hasPrefix(String.withCString(".debug"));
        }
    void set(String* n, u32 sz, u32 rw, u32 rl, u32 nr, u32 ch)
        {
        _name = n;
        _size = sz;
        _raw = rw;
        _rel = rl;
        _nrel = nr;
        _chars = ch;
        }
    }

    class CoffObject
    {
    Data* _d;
    Array* _sections;   // CoffSection@, 1-BASED (index 0 is a placeholder)
    Array* _symdefs;    // ElfSymDef@, parallel to the COFF symbol table
    Array* _relocs;     // ElfReloc@ against text
    Array* _dataRelocs; // ElfReloc@ against data
    Data* _text;
    Data* _data;
    bool _ok;
    Map* _textOffOf; // section index -> offset+1 in the text blob
    Map* _dataOffOf;

    void init(void)
        {
        _sections = new Array();
        _symdefs = new Array();
        _relocs = new Array();
        _dataRelocs = new Array();
        _text = new Data();
        _data = new Data();
        _textOffOf = new Map();
        _dataOffOf = new Map();
        _ok = false;
        }

    bool ok(void)
        {
        return _ok;
        }
    Array* symdefs(void)
        {
        return _symdefs;
        }
    Array* relocs(void)
        {
        return _relocs;
        }
    Array* dataRelocs(void)
        {
        return _dataRelocs;
        }
    Data* text(void)
        {
        return _text;
        }
    Data* data(void)
        {
        return _data;
        }
    // COFF has no separate TLS image and no per-section alignment we honour, so
    // these answer the way ElfMerge expects for an object that has neither.
    Data* tls(void)
        {
        return new Data();
        }
    u32 dataAlign(void)
        {
        return (u32)8;
        }
    u32 tlsAlign(void)
        {
        return (u32)1;
        }
    Array* tlsRelocs(void)
        {
        return new Array();
        }

    static CoffObject* parse(Data* d)
        {
        CoffObject* o = new CoffObject();
        if (d == 0 || d.length() < (u32)20)
            return o;
        // A bare COFF object: the AMD64 machine, and NO optional header. A PE
        // image has one, and is not something to merge.
        if (CoffObject._rd16(d, (u32)0) != (u32)COFF_MACHINE_AMD64)
            return o;
        if (CoffObject._rd16(d, (u32)16) != (u32)0)
            return o;
        o._d = d;
        u32 nsect = CoffObject._rd16(d, (u32)2);
        u32 symOff = CoffObject._rd32(d, (u32)8);
        u32 nsym = CoffObject._rd32(d, (u32)12);
        if (nsect == (u32)0)
            return o;
        if (symOff + nsym * (u32)COFF_SYM_SZ > d.length())
            return o;
        u32 strOff = symOff + nsym * (u32)COFF_SYM_SZ;

        o._sections.add((Object*)new CoffSection()); // index 0: 1-based table
        for (u32 i = (u32)0; i < nsect; i = i + (u32)1)
            {
            u32 s = (u32)20 + i * (u32)COFF_SECT_HDR_SIZE;
            CoffSection* sec = new CoffSection();
            sec.set(CoffObject._name8(d, s),
                    CoffObject._rd32(d, s + (u32)16),
                    CoffObject._rd32(d, s + (u32)20),
                    CoffObject._rd32(d, s + (u32)24),
                    CoffObject._rd16(d, s + (u32)32),
                    CoffObject._rd32(d, s + (u32)36));
            o._sections.add((Object*)sec);
            }
        if (!o._blobs())
            return o;
        o._symbols(symOff, nsym, strOff);
        o._relocations();
        o._ok = true;
        return o;
        }

    bool _blobs(void)
        {
        bool any = false;
        for (u32 i = (u32)1; i < _sections.count(); i = i + (u32)1)
            {
            CoffSection* s = (CoffSection*)_sections.get(i);
            if (!s.isCode() || s.skippable())
                continue;
            _padTo(_text, (u32)16);
            _textOffOf.set((Hashable*)Number.withU32(i),
                           (Object*)Number.withU32(_text.length() + (u32)1));
            _copyInto(_text, s.raw(), s.size());
            any = true;
            }
        if (!any)
            return false;
        for (u32 i = (u32)1; i < _sections.count(); i = i + (u32)1)
            {
            CoffSection* s = (CoffSection*)_sections.get(i);
            if (_in(_textOffOf, i) != (u32)0)
                continue;
            if (s.isCode() || s.skippable())
                continue;
            u32 ch = s.chars();
            if ((ch & ((u32)COFF_SCN_INIT_DATA | (u32)COFF_SCN_UNINIT_DATA)) == (u32)0)
                continue;
            _padTo(_data, (u32)8);
            _dataOffOf.set((Hashable*)Number.withU32(i),
                           (Object*)Number.withU32(_data.length() + (u32)1));
            if ((ch & (u32)COFF_SCN_UNINIT_DATA) != (u32)0)
                _zeros(_data, s.size());
            else
                _copyInto(_data, s.raw(), s.size());
            }
        return true;
        }

    void _symbols(u32 symOff, u32 nsym, u32 strOff)
        {
        u32 i = (u32)0;
        while (i < nsym)
            {
            u32 e = symOff + i * (u32)COFF_SYM_SZ;
            // Inline when it fits in eight bytes; a string-table offset only
            // when the first four are zero.
            String* nm = CoffObject._rd32(_d, e) == (u32)0
                             ? ElfObject._str(_d, strOff + CoffObject._rd32(_d, e + (u32)4))
                             : CoffObject._name8(_d, e);
            u32 val = CoffObject._rd32(_d, e + (u32)8);
            i32 sect = (i32)(i16)CoffObject._rd16(_d, e + (u32)12);
            u32 cls = (u32)_d.byteAt(e + (u32)16);
            u32 naux = (u32)_d.byteAt(e + (u32)17);
            bool ext = cls == (u32)2;
            u32 where = (u32)0;
            u32 off = (u32)0;
            if (sect > (i32)0)
                {
                u32 t = _in(_textOffOf, (u32)sect);
                u32 dd = _in(_dataOffOf, (u32)sect);
                if (t != (u32)0)
                    {
                    where = (u32)1;
                    off = t - (u32)1 + val;
                    }
                else if (dd != (u32)0)
                    {
                    where = (u32)2;
                    off = dd - (u32)1 + val;
                    }
                }
            ElfSymDef* sd = new ElfSymDef();
            sd.set(nm, ext, false, where, off);
            _symdefs.add((Object*)sd);
            // Auxiliary records take slots and relocations index BY SLOT, so
            // they are kept as placeholders. Skipping them renumbers every
            // symbol after the first one.
            for (u32 a = (u32)0; a < naux; a = a + (u32)1)
                {
                i = i + (u32)1;
                ElfSymDef* aux = new ElfSymDef();
                aux.set(new String(), false, false, (u32)0, (u32)0);
                _symdefs.add((Object*)aux);
                }
            i = i + (u32)1;
            }
        }

    void _relocations(void)
        {
        for (u32 i = (u32)1; i < _sections.count(); i = i + (u32)1)
            {
            CoffSection* s = (CoffSection*)_sections.get(i);
            if (s.nrel() == (u32)0)
                continue;
            u32 t = _in(_textOffOf, i);
            u32 dd = _in(_dataOffOf, i);
            if (t == (u32)0 && dd == (u32)0)
                continue; // a skipped section relocates nothing
            u32 base = (t != (u32)0 ? t : dd) - (u32)1;
            Array* into = t != (u32)0 ? _relocs : _dataRelocs;
            for (u32 r = (u32)0; r < s.nrel(); r = r + (u32)1)
                {
                u32 e = s.rel() + r * (u32)COFF_RELOC_SZ;
                u32 roff = CoffObject._rd32(_d, e);
                u32 rsym = CoffObject._rd32(_d, e + (u32)4);
                u32 rt = CoffObject._rd16(_d, e + (u32)8);
                // COFF keeps the addend IN THE SECTION DATA, and a REL32
                // carries an implied +4 that has to come back off.
                i64 addend;
                if (rt == (u32)COFF_REL_ADDR64)
                    addend = (i64)CoffObject._rd64(_d, s.raw() + roff);
                else
                    addend = (i64)(i32)CoffObject._rd32(_d, s.raw() + roff) - (i64)4;
                ElfReloc* rec = new ElfReloc();
                rec.set(roff + base, rsym, rt, addend);
                into.add((Object*)rec);
                }
            }
        }

    Array* definedNames(void)
        {
        Array* out = new Array();
        for (u32 i = (u32)0; i < _symdefs.count(); i = i + (u32)1)
            {
            ElfSymDef* s = (ElfSymDef*)_symdefs.get(i);
            if (s.where() == (u32)0 || !s.ext())
                continue;
            if (s.name() == 0 || s.name().byteLength() == (u32)0)
                continue;
            out.add((Object*)s.name());
            }
        return out;
        }

    Array* undefinedNames(void)
        {
        Array* out = new Array();
        for (u32 i = (u32)0; i < _symdefs.count(); i = i + (u32)1)
            {
            ElfSymDef* s = (ElfSymDef*)_symdefs.get(i);
            if (s.where() != (u32)0 || !s.ext())
                continue;
            if (s.name() == 0 || s.name().byteLength() == (u32)0)
                continue;
            out.add((Object*)s.name());
            }
        return out;
        }

    u32 _in(Map* m, u32 idx)
        {
        Object* v = m.get((Hashable*)Number.withU32(idx));
        if (v == (Object*)0)
            return (u32)0;
        return ((Number*)v).asU32();
        }

    void _padTo(Data* d, u32 a)
        {
        while (d.length() % a != (u32)0)
            d.appendByte((u8)0);
        }

    void _zeros(Data* d, u32 n)
        {
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            d.appendByte((u8)0);
        }

    void _copyInto(Data* d, u32 off, u32 n)
        {
        for (u32 i = (u32)0; i < n && off + i < _d.length(); i = i + (u32)1)
            d.appendByte(_d.byteAt(off + i));
        }

    // An 8-byte inline name, NUL-padded rather than NUL-terminated when full.
    static String* _name8(Data* d, u32 o)
        {
        String* s = new String();
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            {
            u8 c = d.byteAt(o + i);
            if (c == (u8)0)
                break;
            s.appendByte(c);
            }
        return s;
        }

    static u32 _rd16(Data* d, u32 o)
        {
        return (u32)d.byteAt(o) | ((u32)d.byteAt(o + (u32)1) << (u32)8);
        }

    static u32 _rd32(Data* d, u32 o)
        {
        return (u32)d.byteAt(o) | ((u32)d.byteAt(o + (u32)1) << (u32)8) | ((u32)d.byteAt(o + (u32)2) << (u32)16) | ((u32)d.byteAt(o + (u32)3) << (u32)24);
        }

    static u64 _rd64(Data* d, u32 o)
        {
        u64 v = (u64)0;
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            v = v | ((u64)d.byteAt(o + i) << (u64)((u64)8 * (u64)i));
        return v;
        }
    }
