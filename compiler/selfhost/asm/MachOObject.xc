// MachOObject.xc — a BARE arm64 MH_OBJECT (or an archive member), read into
// the shape the linker merges: one __text blob, one data blob concatenating
// every __DATA / __TEXT-literal section, the symbol table with each entry
// classified (undefined / text / data), and the relocations of both blobs.
//
// The mirror of XTMachOWriter's objectAtPath: / objectsInArchive: /
// parseObject: (bug 138: the shipped driver could not consume an object at
// all — a `.o` on its line was parsed as source, and `-Xlinker x.o` became an
// LC_LOAD_DYLIB). Same blob layout, same alignment rules, same section
// classification, so an object the reference emitted and one clang emitted
// arrive in this linker in exactly the shape they arrive in that one.

#import "Foundation.xc"
#import "ArArchive.xc"

#define MACHO_MAGIC_64 $FEEDFACF
#define MACHO_LC_SEG64 $19
#define MACHO_LC_SYMTAB $2

// One symbol-table entry, PARALLEL to the object's nlist order so a
// relocation's r_symbolnum indexes it. where: 0 undefined, 1 text, 2 data.
class MachOSymDef
    {
    String* _name;
    bool _ext;
    u32 _where;
    u32 _off;
    void init(void)
        {
        _ext = false;
        _where = (u32)0;
        _off = (u32)0;
        }
    String* name(void)
        {
        return _name;
        }
    bool ext(void)
        {
        return _ext;
        }
    u32 where(void)
        {
        return _where;
        }
    u32 off(void)
        {
        return _off;
        }
    void set(String* n, bool e, u32 w, u32 o)
        {
        _name = n;
        _ext = e;
        _where = w;
        _off = o;
        }
    }

    // One relocation entry, fields straight out of relocation_info.
    class MachOReloc
    {
    u32 _off; // r_address — blob-relative for data relocs
    u32 _symnum;
    u32 _pcrel;
    u32 _len;
    u32 _ext;
    u32 _type;
    void init(void)
        {
        }
    u32 off(void)
        {
        return _off;
        }
    u32 symnum(void)
        {
        return _symnum;
        }
    u32 pcrel(void)
        {
        return _pcrel;
        }
    u32 len(void)
        {
        return _len;
        }
    u32 ext(void)
        {
        return _ext;
        }
    u32 type(void)
        {
        return _type;
        }
    void set(u32 o, u32 info)
        {
        _off = o;
        _symnum = info & (u32)$FFFFFF;
        _pcrel = (info >> (u32)24) & (u32)1;
        _len = (info >> (u32)25) & (u32)3;
        _ext = (info >> (u32)27) & (u32)1;
        _type = (info >> (u32)28) & (u32)$F;
        }
    }

    // A run of ObjC metadata inside a data blob (bug 069): where an `__objc_*`
    // section landed, with the segment and flags its object gave it. The reader
    // records them in OBJECT-blob coordinates; the merge rebases them to the
    // image; the repartition regroups them; the writer turns each group into a
    // section header so the runtime can find its metadata by section identity.
    class MachOObjcRange
    {
    String* _name;
    String* _seg;
    u32 _flags;
    u32 _off;
    u32 _size;
    void init(void)
        {
        _flags = (u32)0;
        _off = (u32)0;
        _size = (u32)0;
        }
    String* name(void)
        {
        return _name;
        }
    String* seg(void)
        {
        return _seg;
        }
    u32 flags(void)
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
    void setOff(u32 o)
        {
        _off = o;
        }
    static MachOObjcRange* with(String* n, String* sg, u32 fl, u32 o, u32 sz)
        {
        MachOObjcRange* r = new MachOObjcRange();
        r._name = n;
        r._seg = sg;
        r._flags = fl;
        r._off = o;
        r._size = sz;
        return r;
        }
    }

    class MachOSectHdr
    {
    String* _name;
    String* _seg;
    u64 _addr;
    u32 _size;
    u32 _foff;
    u32 _reloff;
    u32 _nreloc;
    u32 _flags;
    void init(void)
        {
        }
    }

    class MachOObject
    {
    Data* _text;
    Data* _data;
    Map* _symbols;      // EXTERNAL text definitions: name -> Number(offset in text)
    Map* _dataSyms;     // EXTERNAL data definitions: name -> Number(offset in blob)
    Array* _symnames;   // String@, nlist order
    Array* _symdefs;    // MachOSymDef@, nlist order
    Array* _relocs;     // MachOReloc@ against __text
    Array* _dataRelocs; // MachOReloc@ against the data blob (blob-relative)
    Array* _objcRanges; // MachOObjcRange@
    Map* _commons;      // common (tentative) NAME -> Number(size), for bug 177
    bool _ok;

    void init(void)
        {
        _text = new Data();
        _data = new Data();
        _symbols = new Map();
        _dataSyms = new Map();
        _symnames = new Array();
        _symdefs = new Array();
        _relocs = new Array();
        _dataRelocs = new Array();
        _objcRanges = new Array();
        _commons = new Map();
        _ok = false;
        }

    bool ok(void)
        {
        return _ok;
        }
    Data* text(void)
        {
        return _text;
        }
    Data* data(void)
        {
        return _data;
        }
    Map* symbols(void)
        {
        return _symbols;
        }
    Map* dataSyms(void)
        {
        return _dataSyms;
        }
    Array* symnames(void)
        {
        return _symnames;
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
    Array* objcRanges(void)
        {
        return _objcRanges;
        }
    Map* commons(void)
        {
        return _commons;
        }

    // A bare MH_OBJECT file, or nothing.
    static MachOObject* atPath(String* path)
        {
        Data* d = Files.readData(path);
        if (d == (Data*)0 || d.length() < (u32)32)
            return (MachOObject*)0;
        if (MachOObject.rd32(d, (u32)0) != (u32)MACHO_MAGIC_64)
            return (MachOObject*)0;
        MachOObject* o = MachOObject.parse(d, (u32)0, d.length());
        return o.ok() ? o : (MachOObject*)0;
        }

    // Every MH_OBJECT member of a `!<arch>` archive, in archive order. The
    // symbol index (`__.SYMDEF`) and anything that is not an object are
    // skipped — a real archive carries those.
    static Array* inArchive(String* path)
        {
        Array* ms = ArArchive.membersOfFile(path);
        if (ms == (Array*)0)
            return (Array*)0;
        Array* out = new Array();
        for (u32 i = (u32)0; i < ms.count(); i = i + (u32)1)
            {
            ArMember* m = (ArMember*)ms.get(i);
            Data* md = m.data();
            if (md == (Data*)0 || md.length() < (u32)32)
                continue;
            if (MachOObject.rd32(md, (u32)0) != (u32)MACHO_MAGIC_64)
                continue;
            MachOObject* o = MachOObject.parse(md, (u32)0, md.length());
            if (o.ok())
                out.add((Object*)o);
            }
        return out;
        }

    // Parse one MH_OBJECT at `base`. Mirrors parseObject: in the reference —
    // the blob layout it produces is what the merge's byte positions depend on.
    static MachOObject* parse(Data* b, u32 base, u32 len)
        {
        MachOObject* o = new MachOObject();
        if (MachOObject.rd32(b, base + (u32)12) != (u32)1)
            return o; // MH_OBJECT
        u32 ncmds = MachOObject.rd32(b, base + (u32)16);
        u32 symoff = (u32)0;
        u32 nsyms = (u32)0;
        u32 stroff = (u32)0;
        Array* sects = new Array(); // 1-based like n_sect
        sects.add((Object*)new MachOSectHdr());
        u32 p = base + (u32)32;
        for (u32 i = (u32)0; i < ncmds; i = i + (u32)1)
            {
            u32 cmd = MachOObject.rd32(b, p);
            u32 csz = MachOObject.rd32(b, p + (u32)4);
            if (cmd == (u32)MACHO_LC_SEG64)
                {
                u32 nsects = MachOObject.rd32(b, p + (u32)64);
                u32 so = p + (u32)72;
                for (u32 s = (u32)0; s < nsects; s = s + (u32)1)
                    {
                    MachOSectHdr* h = new MachOSectHdr();
                    h._name = MachOObject.fixed(b, so, (u32)16);
                    h._seg = MachOObject.fixed(b, so + (u32)16, (u32)16);
                    h._addr = MachOObject.rd64(b, so + (u32)32);
                    h._size = (u32)MachOObject.rd64(b, so + (u32)40);
                    h._foff = base + MachOObject.rd32(b, so + (u32)48);
                    h._reloff = base + MachOObject.rd32(b, so + (u32)56);
                    h._nreloc = MachOObject.rd32(b, so + (u32)60);
                    h._flags = MachOObject.rd32(b, so + (u32)64);
                    sects.add((Object*)h);
                    so = so + (u32)80;
                    }
                }
            else if (cmd == (u32)MACHO_LC_SYMTAB)
                {
                symoff = MachOObject.rd32(b, p + (u32)8);
                nsyms = MachOObject.rd32(b, p + (u32)12);
                stroff = MachOObject.rd32(b, p + (u32)16);
                }
            p = p + csz;
            }
        u32 textIdx = (u32)0;
        for (u32 i = (u32)1; i < sects.count(); i = i + (u32)1)
            if (((MachOSectHdr*)sects.get(i))._name.equals(String.withCString("__text")))
                {
                textIdx = i;
                break;
                }
        if (textIdx == (u32)0)
            return o;
        MachOSectHdr* ts = (MachOSectHdr*)sects.get(textIdx);
        MachOObject.copyInto(o._text, b, ts._foff, ts._size);
        u64 textAddr = ts._addr;

        // The data blob: every __DATA / __DATA_CONST section and every __TEXT
        // literal pool (by section TYPE — clang parks float constants in
        // __literal4/8/16 and addresses them through private labels), each
        // at 8 (16 for 16-byte literals) relative to the blob start.
        Map* blobOff = new Map(); // sect index -> Number(off + 1)
        Array* dataSectIdx = new Array();
        for (u32 i = (u32)1; i < sects.count(); i = i + (u32)1)
            {
            if (i == textIdx)
                continue;
            MachOSectHdr* s = (MachOSectHdr*)sects.get(i);
            u32 stype = s._flags & (u32)$FF;
            bool isText = s._seg.equals(String.withCString("__TEXT"));
            bool textLiteral = isText && (stype == (u32)2 || stype == (u32)3 || stype == (u32)4 || stype == (u32)$E || stype == (u32)5 || s._name.equals(String.withCString("__const")) || s._name.equals(String.withCString("__cstring")));
            bool dataLike = s._seg.equals(String.withCString("__DATA")) || s._seg.equals(String.withCString("__DATA_CONST")) || textLiteral;
            if (!dataLike)
                continue; // __compact_unwind / __LD / debug
            u32 alignTo = stype == (u32)$E ? (u32)15 : (u32)7;
            while ((o._data.length() & alignTo) != (u32)0)
                o._data.appendByte((u8)0);
            blobOff.set((Hashable*)Number.withU32(i), (Object*)Number.withU32(o._data.length() + (u32)1));
            dataSectIdx.add((Object*)Number.withU32(i));
            if (s._name.hasPrefix(String.withCString("__objc_")))
                o._objcRanges.add((Object*)MachOObjcRange.with(s._name, s._seg, s._flags,
                                                               o._data.length(), s._size));
            if (stype == (u32)1 || stype == (u32)$C || stype == (u32)$12)
                MachOObject.zeros(o._data, s._size); // zero-fill
            else
                MachOObject.copyInto(o._data, b, s._foff, s._size);
            }

        // Common (tentative) symbols get zero-filled blob space of their own:
        // N_UNDF|N_EXT, n_sect 0, n_value = the SIZE, alignment in n_desc.
        Map* commonOff = new Map(); // name -> Number(off + 1)
        for (u32 i = (u32)0; i < nsyms; i = i + (u32)1)
            {
            u32 e = base + symoff + i * (u32)16;
            u32 type = (u32)b.byteAt(e + (u32)4);
            u32 sect = (u32)b.byteAt(e + (u32)5);
            u32 desc = (u32)b.byteAt(e + (u32)6) | ((u32)b.byteAt(e + (u32)7) << (u32)8);
            u64 val = MachOObject.rd64(b, e + (u32)8);
            if ((type & (u32)$E) != (u32)0 || (type & (u32)1) == (u32)0 || sect != (u32)0 || val == (u64)0)
                continue;
            String* n = MachOObject.str(b, base + stroff + MachOObject.rd32(b, e));
            if (n.byteLength() == (u32)0 || commonOff.get((Hashable*)n) != (Object*)0)
                continue;
            u32 align = (desc >> (u32)8) & (u32)$F;
            u32 amask = ((u32)1 << (align != (u32)0 ? align : (u32)3)) - (u32)1;
            if (amask < (u32)7)
                amask = (u32)7;
            while ((o._data.length() & amask) != (u32)0)
                o._data.appendByte((u8)0);
            commonOff.set((Hashable*)n, (Object*)Number.withU32(o._data.length() + (u32)1));
            o._commons.set((Hashable*)n, (Object*)Number.withU32((u32)val)); // bug 177
            MachOObject.zeros(o._data, (u32)val);
            }

        // Every symbol, classified. Externals also join the two maps the
        // archive pull keys off.
        for (u32 i = (u32)0; i < nsyms; i = i + (u32)1)
            {
            u32 e = base + symoff + i * (u32)16;
            u32 strx = MachOObject.rd32(b, e);
            u32 type = (u32)b.byteAt(e + (u32)4);
            u32 sect = (u32)b.byteAt(e + (u32)5);
            u64 val = MachOObject.rd64(b, e + (u32)8);
            String* n = MachOObject.str(b, base + stroff + strx);
            u32 where = (u32)0;
            u32 off = (u32)0;
            bool ext = (type & (u32)1) != (u32)0;
            // N_SECT
            if ((type & (u32)$E) == (u32)$E)
                {
                if (sect == textIdx)
                    {
                    where = (u32)1;
                    off = (u32)(val - textAddr);
                    }
                else
                    {
                    Object* bo = blobOff.get((Hashable*)Number.withU32(sect));
                    if (bo != (Object*)0)
                        {
                        MachOSectHdr* sh = (MachOSectHdr*)sects.get(sect);
                        where = (u32)2;
                        off = (((Number*)bo).asU32() - (u32)1) + (u32)(val - sh._addr);
                        }
                    }
                }
            else
                {
                Object* co = commonOff.get((Hashable*)n);
                if (co != (Object*)0)
                    {
                    where = (u32)2;
                    off = ((Number*)co).asU32() - (u32)1;
                    }
                }
            MachOSymDef* sd = new MachOSymDef();
            sd.set(n, ext, where, off);
            o._symnames.add((Object*)n);
            o._symdefs.add((Object*)sd);
            if (n.byteLength() > (u32)0 && ext && where == (u32)1)
                o._symbols.set((Hashable*)n, (Object*)Number.withU32(off));
            else if (n.byteLength() > (u32)0 && ext && where == (u32)2)
                o._dataSyms.set((Hashable*)n, (Object*)Number.withU32(off));
            }

        // __text relocations, then each data section's, the latter rebased
        // from section-relative to blob-relative.
        for (u32 i = (u32)0; i < ts._nreloc; i = i + (u32)1)
            {
            u32 r = ts._reloff + i * (u32)8;
            MachOReloc* rl = new MachOReloc();
            rl.set(MachOObject.rd32(b, r), MachOObject.rd32(b, r + (u32)4));
            o._relocs.add((Object*)rl);
            }
        for (u32 k = (u32)0; k < dataSectIdx.count(); k = k + (u32)1)
            {
            u32 si = ((Number*)dataSectIdx.get(k)).asU32();
            MachOSectHdr* s = (MachOSectHdr*)sects.get(si);
            u32 bo = ((Number*)blobOff.get((Hashable*)Number.withU32(si))).asU32() - (u32)1;
            for (u32 i = (u32)0; i < s._nreloc; i = i + (u32)1)
                {
                u32 r = s._reloff + i * (u32)8;
                MachOReloc* rl = new MachOReloc();
                rl.set(bo + MachOObject.rd32(b, r), MachOObject.rd32(b, r + (u32)4));
                o._dataRelocs.add((Object*)rl);
                }
            }
        o._ok = true;
        return o;
        }

    // Does this object define any name in `needed` (a Map of name -> 1)?
    bool definesAny(Map* needed)
        {
        Array* ks = _symbols.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            if (needed.get((Hashable*)ks.get(i)) != (Object*)0)
                return true;
        ks = _dataSyms.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            if (needed.get((Hashable*)ks.get(i)) != (Object*)0)
                return true;
        return false;
        }

    // ── byte helpers ─────────────────────────────────────────────────────
    static u32 rd32(Data* d, u32 o)
        {
        return (u32)d.byteAt(o) | ((u32)d.byteAt(o + (u32)1) << (u32)8) | ((u32)d.byteAt(o + (u32)2) << (u32)16) | ((u32)d.byteAt(o + (u32)3) << (u32)24);
        }
    static u64 rd64(Data* d, u32 o)
        {
        u64 v = (u64)0;
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            v = v | ((u64)d.byteAt(o + i) << (u64)((u64)8 * (u64)i));
        return v;
        }
    static String* str(Data* d, u32 o)
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
    static String* fixed(Data* d, u32 o, u32 n)
        {
        String* s = new String();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            u8 c = d.byteAt(o + i);
            if (c == (u8)0)
                break;
            s.appendByte(c);
            }
        return s;
        }
    static void copyInto(Data* dst, Data* src, u32 off, u32 n)
        {
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            dst.appendByte(src.byteAt(off + i));
        }
    static void zeros(Data* dst, u32 n)
        {
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            dst.appendByte((u8)0);
        }
    }
