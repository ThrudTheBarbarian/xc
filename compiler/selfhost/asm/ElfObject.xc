// ElfObject.xc — reading a FOREIGN ELF64 relocatable object.
// =================================================================
//
// The port's linker writes executables from its own assembled output. To link
// against a real libc it has to read objects it did not produce — musl's, built
// by clang — which is a different job: section table, symbol table, and the
// relocations that tie them together (task #47).
//
// The output shape mirrors the reference's `objectFromData:` exactly, because
// the merge step downstream is the same algorithm: three blobs (text, data,
// thread-local), a note of where each input section landed in its blob, the
// symbols classified by which blob defines them, and the relocations rebased
// into blob coordinates.
//
// Four details carried from the reference, each of which cost a debugging
// session there and would have cost another here:
//
//   * EVERY executable section is code, not just the first. A library built
//     with -ffunction-sections puts each function in its own `.text.<name>`
//     and leaves `.text` empty, so taking the first one yields a zero-length
//     blob and classifies every function in the member as undefined.
//   * A section's OWN alignment is load-bearing. `movaps` faults outright on a
//     16-byte constant that landed on an 8-byte boundary, and musl's
//     .rodata.cst16 is full of them.
//   * .tdata/.tbss are NOT data. Their bytes are a per-thread initialisation
//     image and their symbols' values are offsets within a thread's block, so
//     they get their own blob — and a TLS symbol must be classified BEFORE the
//     address branch, or that branch claims it and the offset is lost.
//   * A COMMON symbol has no section at all: st_value is its ALIGNMENT and
//     st_size its size, and the linker is what allocates it.
#import "Foundation.xc"

// Where a symbol is defined: 0 = nowhere (undefined), 1 = text, 2 = data,
// 3 = thread-local.
class ElfSymDef
    {
    String* _name;
    bool _ext; // visible outside this object (bind != LOCAL)
    bool _weak;
    u32 _where;
    u32 _off;   // offset within that blob
    u32 _size;  // COMMON byte size (where==5); 0 otherwise
    u32 _align; // COMMON alignment (where==5)
    void init(void)
        {
        _size = (u32)0;
        _align = (u32)1;
        }
    String* name(void)
        {
        return _name;
        }
    bool ext(void)
        {
        return _ext;
        }
    bool weak(void)
        {
        return _weak;
        }
    u32 where(void)
        {
        return _where;
        }
    u32 off(void)
        {
        return _off;
        }
    u32 size(void)
        {
        return _size;
        }
    u32 align(void)
        {
        return _align;
        }
    void setCommon(u32 sz, u32 al)
        {
        _size = sz;
        _align = al;
        }
    void setSize(u32 sz)
        {
        _size = sz;
        }
    void set(String* n, bool e, bool w, u32 wh, u32 o)
        {
        _name = n;
        _ext = e;
        _weak = w;
        _where = wh;
        _off = o;
        }
    }

    class ElfReloc
    {
    u32 _off;  // offset into the blob this reloc patches
    u32 _sym;  // index into symdefs
    u32 _type; // R_X86_64_*
    i64 _addend;
    void init(void)
        {
        }
    u32 off(void)
        {
        return _off;
        }
    u32 sym(void)
        {
        return _sym;
        }
    u32 type(void)
        {
        return _type;
        }
    i64 addend(void)
        {
        return _addend;
        }
    void set(u32 o, u32 s, u32 t, i64 a)
        {
        _off = o;
        _sym = s;
        _type = t;
        _addend = a;
        }
    }

    class ElfSection
    {
    String* _name;
    u32 _type;
    u64 _flags;
    u32 _off;
    u32 _size;
    u32 _link;
    u32 _info;
    u32 _align;
    void init(void)
        {
        }
    String* name(void)
        {
        return _name;
        }
    u32 type(void)
        {
        return _type;
        }
    u64 flags(void)
        {
        return _flags;
        }
    u32 off(void)
        {
        return _off;
        }
    u32 size(void)
        {
        return _size;
        }
    u32 link(void)
        {
        return _link;
        }
    u32 info(void)
        {
        return _info;
        }
    u32 align(void)
        {
        return _align < (u32)1 ? (u32)1 : _align;
        }
    bool isCode(void)
        {
        return _type == (u32)1 && (_flags & (u64)4) != (u64)0;
        }
    void set(String* n, u32 t, u64 f, u32 o, u32 s, u32 l, u32 inf, u32 a)
        {
        _name = n;
        _type = t;
        _flags = f;
        _off = o;
        _size = s;
        _link = l;
        _info = inf;
        _align = a;
        }
    }

    class ElfObject
    {
    Data* _d;
    Array* _sections;   // ElfSection@
    Array* _symdefs;    // ElfSymDef@, PARALLEL to the object's symbol table
    Array* _relocs;     // ElfReloc@ against text
    Array* _dataRelocs; // ElfReloc@ against data
    Array* _tlsRelocs;  // ElfReloc@ against the TLS image
    Data* _text;
    Data* _data;
    Data* _tls;
    u32 _dataAlign;
    u32 _tlsAlign;
    bool _ok;

    // Section index -> offset-in-blob PLUS ONE, so that 0 means "not in this
    // blob" and a section genuinely at offset 0 is still distinguishable.
    Map* _textOffOf;
    Map* _dataOffOf;
    Map* _tlsOffOf;

    void init(void)
        {
        _sections = new Array();
        _symdefs = new Array();
        _relocs = new Array();
        _dataRelocs = new Array();
        _tlsRelocs = new Array();
        _text = new Data();
        _data = new Data();
        _tls = new Data();
        _textOffOf = new Map();
        _dataOffOf = new Map();
        _tlsOffOf = new Map();
        _dataAlign = (u32)1;
        _tlsAlign = (u32)1;
        _ok = false;
        }

    bool ok(void)
        {
        return _ok;
        }
    Array* sections(void)
        {
        return _sections;
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
    Array* tlsRelocs(void)
        {
        return _tlsRelocs;
        }
    Data* text(void)
        {
        return _text;
        }
    Data* data(void)
        {
        return _data;
        }
    Data* tls(void)
        {
        return _tls;
        }
    u32 dataAlign(void)
        {
        return _dataAlign;
        }
    // Where each input section landed in its blob (bug 196 GC unit boundaries).
    Array* textSecStarts(void)
        {
        return ElfObject._starts(_textOffOf);
        }
    Array* dataSecStarts(void)
        {
        return ElfObject._starts(_dataOffOf);
        }
    static Array* _starts(Map* m)
        {
        Array* out = new Array();
        Array* ks = m.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            out.add((Object*)Number.withU32(((Number*)m.get((Hashable*)ks.get(i))).asU32() - (u32)1));
        return out;
        }
    u32 tlsAlign(void)
        {
        return _tlsAlign;
        }

    // ELF64 little-endian ET_REL, or nothing. A member that is not an object —
    // real archives carry those — is SKIPPED by the caller, not refused.
    static ElfObject* parse(Data* d)
        {
        ElfObject* o = new ElfObject();
        if (d == 0 || d.length() < (u32)64)
            return o;
        if (d.byteAt((u32)0) != (u8)$7F || d.byteAt((u32)1) != (u8)'E' || d.byteAt((u32)2) != (u8)'L' || d.byteAt((u32)3) != (u8)'F')
            return o;
        if (d.byteAt((u32)4) != (u8)2 || d.byteAt((u32)5) != (u8)1)
            return o; // 64-bit LE
        if (ElfObject._rd16(d, (u32)16) != (u32)1)
            return o; // ET_REL
        o._d = d;
        u32 shoff = (u32)ElfObject._rd64(d, (u32)40);
        u32 shent = ElfObject._rd16(d, (u32)58);
        u32 shnum = ElfObject._rd16(d, (u32)60);
        u32 shstrn = ElfObject._rd16(d, (u32)62);
        if (shnum == (u32)0 || shent == (u32)0)
            return o;
        if (shoff + shnum * shent > d.length())
            return o;

        u32 shstrHdr = shoff + shstrn * shent;
        u32 shstrOff = (u32)ElfObject._rd64(d, shstrHdr + (u32)24);
        for (u32 i = (u32)0; i < shnum; i = i + (u32)1)
            {
            u32 s = shoff + i * shent;
            ElfSection* sec = new ElfSection();
            sec.set(ElfObject._str(d, shstrOff + ElfObject._rd32(d, s)),
                    ElfObject._rd32(d, s + (u32)4),
                    ElfObject._rd64(d, s + (u32)8),
                    (u32)ElfObject._rd64(d, s + (u32)24),
                    (u32)ElfObject._rd64(d, s + (u32)32),
                    ElfObject._rd32(d, s + (u32)40),
                    ElfObject._rd32(d, s + (u32)44),
                    (u32)ElfObject._rd64(d, s + (u32)48));
            o._sections.add((Object*)sec);
            }
        if (!o._blobs())
            return o;
        if (!o._symbols())
            return o;
        o._relocations();
        o._ok = true;
        return o;
        }

    // ── the three blobs ──────────────────────────────────────────────────
    bool _blobs(void)
        {
        u32 n = _sections.count();
        // Text: every executable PROGBITS section, 16-byte aligned at minimum.
        for (u32 i = (u32)1; i < n; i = i + (u32)1)
            {
            ElfSection* s = (ElfSection*)_sections.get(i);
            if (!s.isCode())
                continue;
            u32 a = s.align() < (u32)16 ? (u32)16 : s.align();
            _padTo(_text, a);
            _textOffOf.set((Hashable*)Number.with(i), (Object*)Number.with(_text.length() + (u32)1));
            _copyInto(_text, s.off(), s.size());
            }
        if (_textOffOf.count() == (u32)0)
            return false;

        for (u32 i = (u32)1; i < n; i = i + (u32)1)
            {
            ElfSection* s = (ElfSection*)_sections.get(i);
            if (_in(_textOffOf, i) != (u32)0)
                continue;
            if ((s.flags() & (u64)2) == (u64)0)
                continue; // SHF_ALLOC
            if (s.type() != (u32)1 && s.type() != (u32)8)
                continue; // PROGBITS / NOBITS
            if ((s.flags() & (u64)4) != (u64)0)
                continue; // executable: already taken
            // SHF_TLS
            if ((s.flags() & (u64)1024) != (u64)0)
                {
                _padTo(_tls, s.align());
                _tlsOffOf.set((Hashable*)Number.with(i), (Object*)Number.with(_tls.length() + (u32)1));
                if (s.type() == (u32)8)
                    _zeros(_tls, s.size());
                else
                    _copyInto(_tls, s.off(), s.size());
                if (s.align() > _tlsAlign)
                    _tlsAlign = s.align();
                continue;
                }
            _padTo(_data, s.align());
            _dataOffOf.set((Hashable*)Number.with(i), (Object*)Number.with(_data.length() + (u32)1));
            if (s.type() == (u32)8)
                _zeros(_data, s.size());
            else
                _copyInto(_data, s.off(), s.size());
            if (s.align() > _dataAlign)
                _dataAlign = s.align();
            }
        return true;
        }

    // ── the symbol table ─────────────────────────────────────────────────
    bool _symbols(void)
        {
        u32 symIdx = (u32)0;
        for (u32 i = (u32)1; i < _sections.count(); i = i + (u32)1)
            if (((ElfSection*)_sections.get(i)).type() == (u32)2)
                {
                symIdx = i;
                break;
                }
        if (symIdx == (u32)0)
            return false;
        ElfSection* st = (ElfSection*)_sections.get(symIdx);
        ElfSection* strs = (ElfSection*)_sections.get(st.link());
        u32 nsym = st.size() / (u32)24;
        for (u32 i = (u32)0; i < nsym; i = i + (u32)1)
            {
            u32 e = st.off() + i * (u32)24;
            String* nm = ElfObject._str(_d, strs.off() + ElfObject._rd32(_d, e));
            u32 info = (u32)_d.byteAt(e + (u32)4);
            u32 shndx = ElfObject._rd16(_d, e + (u32)6);
            u32 val = (u32)ElfObject._rd64(_d, e + (u32)8);
            bool ext = (info >> (u32)4) != (u32)0; // STB_LOCAL is 0
            bool weak = (info >> (u32)4) == (u32)2;
            u32 where = (u32)0;
            u32 off = (u32)0;
            if ((info & (u32)15) == (u32)6 && shndx != (u32)0 && shndx < _sections.count())
                {
                // STT_TLS: st_value is an offset within its TLS section.
                // Classified FIRST — the address branch below would claim it.
                u32 t = _in(_tlsOffOf, shndx);
                if (t != (u32)0)
                    {
                    where = (u32)3;
                    off = t - (u32)1 + val;
                    }
                }
            else if (shndx != (u32)0 && shndx < _sections.count())
                {
                u32 t = _in(_textOffOf, shndx);
                u32 dd = _in(_dataOffOf, shndx);
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
            else if (shndx == (u32)$FFF2)
                {
                // SHN_COMMON: st_value is the ALIGNMENT, st_size the byte count,
                // no section holds it. Record it as a BSS request (where=5) with
                // its size/align; the merge allocates ONE slot per name in the
                // NOBITS bss region (folded onto the end of .data by finalizeBss),
                // so it costs memory but not FILE size — a 50 MB uninitialised
                // global was 50 MB of stored zeros in .data before this (bug 195
                // .bss half, re-landed after the crt thread-list fix, bug 197).
                where = (u32)5;
                off = (u32)0;
                u32 algn = val != (u32)0 ? val : (u32)8;
                u32 csize = (u32)ElfObject._rd64(_d, e + (u32)16);
                ElfSymDef* cd = new ElfSymDef();
                cd.set(nm, ext, weak, where, off);
                cd.setCommon(csize != (u32)0 ? csize : (u32)8, algn);
                _symdefs.add((Object*)cd);
                continue;
                }
            ElfSymDef* sd = new ElfSymDef();
            sd.set(nm, ext, weak, where, off);
            sd.setSize((u32)ElfObject._rd64(_d, e + (u32)16)); // st_size: function extent (bug 196 GC)
            _symdefs.add((Object*)sd);
            }
        return true;
        }

    // ── relocations, routed by the section each RELA applies to ──────────
    void _relocations(void)
        {
        for (u32 i = (u32)1; i < _sections.count(); i = i + (u32)1)
            {
            ElfSection* s = (ElfSection*)_sections.get(i);
            if (s.type() != (u32)4)
                continue; // SHT_RELA
            u32 applies = s.info();
            u32 t = _in(_textOffOf, applies);
            u32 dd = _in(_dataOffOf, applies);
            u32 l = _in(_tlsOffOf, applies);
            if (t == (u32)0 && dd == (u32)0 && l == (u32)0)
                continue; // e.g. .rela.eh_frame
            u32 base = (t != (u32)0 ? t : (dd != (u32)0 ? dd : l)) - (u32)1;
            Array* into = t != (u32)0 ? _relocs : (dd != (u32)0 ? _dataRelocs : _tlsRelocs);
            u32 n = s.size() / (u32)24;
            for (u32 r = (u32)0; r < n; r = r + (u32)1)
                {
                u32 e = s.off() + r * (u32)24;
                u64 rinfo = ElfObject._rd64(_d, e + (u32)8);
                ElfReloc* rec = new ElfReloc();
                rec.set((u32)ElfObject._rd64(_d, e) + base,
                        (u32)(rinfo >> (u64)32),
                        (u32)(rinfo & (u64)$FFFFFFFF),
                        (i64)ElfObject._rd64(_d, e + (u32)16));
                into.add((Object*)rec);
                }
            }
        }

    // ── helpers ──────────────────────────────────────────────────────────
    u32 _in(Map* m, u32 idx)
        {
        Object* v = m.get((Hashable*)Number.with(idx));
        if (v == (Object*)0)
            return (u32)0;
        return ((Number*)v).asU32();
        }

    void _padTo(Data* d, u32 a)
        {
        if (a < (u32)1)
            a = (u32)1;
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

    // What this object DEFINES for others: external, with a home.
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

    // What it NEEDS from elsewhere.
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

    static String* _str(Data* d, u32 o)
        {
        String* s = new String();
        for (u32 i = o; i < d.length(); i = i + (u32)1)
            {
            u8 c = d.byteAt(i);
            if (c == (u8)0)
                break;
            s.appendByte(c);
            }
        return s;
        }
    }
