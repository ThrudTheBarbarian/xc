// Pe.xc — write a Windows x86-64 PE/COFF executable.
// =================================================================
//
// self-hosting M22, a port of `XTPEWriter`. The instruction encoder is shared
// with the Linux target — `xtc -A win64` uses the same back end and the same
// directive set — so what is new here is only the container.
//
// How PE differs from ELF, in the ways that matter:
//
//   * Everything is an RVA, an offset from ImageBase, and file offsets are a
//     SEPARATE alignment (512 against the section alignment's 4096). ELF lets
//     p_offset and p_vaddr be congruent and largely interchange; PE does not,
//     so each section carries both independently.
//   * There is no GOT. Imports go through an Import Directory Table naming each
//     DLL, with a parallel ILT/IAT pair of thunks the loader overwrites, so a
//     `call foo` has to become `call <stub>` where the stub is a jump through
//     the IAT slot.
//   * Windows has no stable syscall ABI, so unlike Linux a freestanding binary
//     CANNOT avoid imports: kernel32.dll is the floor.
//
// ImageBase is 0x1_4000_0000, the one address here that does not fit 32 bits.
// Every relative calculation cancels it, so the port works in RVA space and
// splits the base into its two halves only where a 64-bit VA is actually
// written.

#import "Foundation.xc"
#import "X86Asm.xc"
#import "CoffObject.xc"

#define PE_FILE_ALIGN $200
#define PE_SECT_ALIGN $1000
#define PE_OPT_HDR_SIZE 240
#define PE_SECT_HDR_SIZE 40
#define PE_THUNK_SZ 6
#define PE_BASE_LO $40000000
#define PE_BASE_HI 1

class Pe
    {
    Array* _out;
    bool _failed;
    String* _why;

    void init(void)
        {
        _out = new Array();
        _failed = false;
        }

    Array* bytes(void)
        {
        return _out;
        }
    bool failed(void)
        {
        return _failed;
        }
    String* why(void)
        {
        return _why;
        }

    void fail(String* m)
        {
        if (!_failed)
            {
            _failed = true;
            _why = m;
            }
        }

    void failWith(String* what, String* detail)
        {
        String* m = new String();
        m.append(what);
        if (detail != (String*)0)
            {
            m.appendCString(" '");
            m.append(detail);
            m.appendCString("'");
            }
        fail(m);
        }

    void p8(u32 v)
        {
        _out.add((Object*)Number.withU32(v & (u32)$FF));
        }
    void p16(u32 v)
        {
        p8(v);
        p8(v >> (u32)8);
        }
    void p32(u32 v)
        {
        p8(v);
        p8(v >> (u32)8);
        p8(v >> (u32)16);
        p8(v >> (u32)24);
        }
    void p64(u32 lo, u32 hi)
        {
        p32(lo);
        p32(hi);
        }
    void padTo(u32 off)
        {
        while (_out.count() < off)
            p8((u32)0);
        }

    static u32 alignUp(u32 v, u32 a)
        {
        return (v + a - (u32)1) & ~(a - (u32)1);
        }

    // Trailing zeros need no file bytes: a section whose VirtualSize exceeds its
    // SizeOfRawData is zero-filled by the loader.
    static u32 rawSizeOf(Array* d)
        {
        u32 n = d.count();
        while (n > (u32)0 && ((Number*)d.get(n - (u32)1)).asU32() == (u32)0)
            n = n - (u32)1;
        return n;
        }

    static bool inArray(Array* a, String* nm)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(nm))
                return true;
        return false;
        }

    static Array* copyBytes(Array* a)
        {
        Array* o = new Array();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            o.add(a.get(i));
        return o;
        }

    // ── Import collection ────────────────────────────────────────────────
    //
    // Only what is actually referenced gets a descriptor: an unused DLL in the
    // import table is a load-time dependency the program does not need.
    Array* _dllOrder; // String@
    Array* _usedSyms; // Array@ of String@, parallel to _dllOrder
    Map* _iatIndex;   // symbol -> its STUB number (order of discovery)
    Map* _iatSlot;    // symbol -> its IAT slot (per-DLL, terminators counted)
    Array* _stubSym;  // stub i -> its symbol
    u32 _nImports;

    // ── COFF relocatable: the write direction (`xcc -c`, bug 139/141) ────
    // The text and data verbatim, every fixup a relocation with its addend
    // stored IN the section bytes (COFF keeps it there; a REL32 carries an
    // implied +4), every symbol it names an entry — defined text, defined
    // data, then undefined, each group sorted so two builds of one input
    // cannot differ by enumeration order. A defined name that was never
    // `.globl` stays STATIC. Mirrors XTPEWriter's objectFromText.
    static void sortStrings(Array* a)
        {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1)
            {
            Object* v = a.get(i);
            u32 j = i;
            while (j > (u32)0 && ((String*)a.get(j - (u32)1)).compare((String*)v) > (i8)0)
                {
                a.set(j, a.get(j - (u32)1));
                j = j - (u32)1;
                }
            a.set(j, v);
            }
        }
    Array* objectFromText(Array* text, Array* data, Map* symbols, Array* dataSyms,
                          Array* globalSyms, Array* fixups)
        {
        Array* mtext = Pe.copyBytes(text);
        Array* mdata = Pe.copyBytes(data);
        Array* defText = new Array();
        Array* defData = new Array();
        Array* names = symbols.allKeys();
        Pe.sortStrings(names);
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* n = (String*)names.get(i);
            if (n.hasPrefix(String.withCString(".L")))
                continue;
            if (Pe.inArray(dataSyms, n))
                defData.add((Object*)n);
            else
                defText.add((Object*)n);
            }
        Array* undef = new Array();
        Map* undefSeen = new Map();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)fixups.get(i);
            if (f.symbol() == (String*)0 || symbols.get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            if (undefSeen.get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            undefSeen.set((Hashable*)f.symbol(), (Object*)Number.withU32((u32)1));
            undef.add((Object*)f.symbol());
            }
        Pe.sortStrings(undef);
        Array* order = new Array();
        for (u32 i = (u32)0; i < defText.count(); i = i + (u32)1)
            order.add(defText.get(i));
        for (u32 i = (u32)0; i < defData.count(); i = i + (u32)1)
            order.add(defData.get(i));
        for (u32 i = (u32)0; i < undef.count(); i = i + (u32)1)
            order.add(undef.get(i));
        Map* symIndex = new Map();
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            symIndex.set((Hashable*)order.get(i), (Object*)Number.withU32(i + (u32)1)); // +1: 0 = absent
        Array* textRel = new Array();
        Array* dataRel = new Array();
        u32 nTextRel = (u32)0;
        u32 nDataRel = (u32)0;
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)fixups.get(i);
            Object* si = f.symbol() == (String*)0 ? (Object*)0 : symIndex.get((Hashable*)f.symbol());
            if (si == (Object*)0)
                continue;
            u32 sidx = ((Number*)si).asU32() - (u32)1;
            if (f.kind() == (u32)X86FIX_ABS64)
                {
                if (f.offset() + (u32)8 > mdata.count())
                    {
                    failWith(String.withCString("abs64 fixup past end of data"), f.symbol());
                    return (Array*)0;
                    }
                u32 v = (u32)f.addend();
                u32 hi = f.addend() < (i32)0 ? (u32)$FFFFFFFF : (u32)0;
                for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
                    mdata.set(f.offset() + b, (Object*)Number.withU32((v >> (b * (u32)8)) & (u32)$FF));
                for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
                    mdata.set(f.offset() + (u32)4 + b, (Object*)Number.withU32((hi >> (b * (u32)8)) & (u32)$FF));
                Pe.rel(dataRel, f.offset(), sidx, (u32)COFF_REL_ADDR64);
                nDataRel = nDataRel + (u32)1;
                continue;
                }
            if (f.offset() + (u32)4 > mtext.count())
                {
                failWith(String.withCString("rel32 fixup past end of text"), f.symbol());
                return (Array*)0;
                }
            u32 inl = (u32)(f.addend() + (i32)4);
            for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
                mtext.set(f.offset() + b, (Object*)Number.withU32((inl >> (b * (u32)8)) & (u32)$FF));
            Pe.rel(textRel, f.offset(), sidx, (u32)COFF_REL_REL32);
            nTextRel = nTextRel + (u32)1;
            }
        // String table: names of 8 bytes or fewer are inlined, longer ones live here.
        Array* strtab = new Array();
        for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
            strtab.add((Object*)Number.withU32((u32)0));
        Array* strx = new Array();
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            String* n = (String*)order.get(i);
            if (n.byteLength() <= (u32)8)
                {
                strx.add((Object*)Number.withU32((u32)0));
                continue;
                }
            strx.add((Object*)Number.withU32(strtab.count()));
            for (u32 b = (u32)0; b < n.byteLength(); b = b + (u32)1)
                strtab.add((Object*)Number.withU32((u32)n.byteAt(b)));
            strtab.add((Object*)Number.withU32((u32)0));
            }
        u32 stsz = strtab.count();
        for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
            strtab.set(b, (Object*)Number.withU32((stsz >> (b * (u32)8)) & (u32)$FF));
        u32 off = (u32)20 + (u32)2 * (u32)PE_SECT_HDR_SIZE;
        u32 textOff = off;
        off = off + mtext.count();
        u32 dataOff = off;
        off = off + mdata.count();
        u32 trelOff = off;
        off = off + textRel.count();
        u32 drelOff = off;
        off = off + dataRel.count();
        u32 symOff = off;
        _out = new Array();
        p16((u32)COFF_MACHINE_AMD64);
        p16((u32)2);
        p32((u32)0); // TimeDateStamp: zero keeps it reproducible
        p32(symOff);
        p32(order.count());
        p16((u32)0);
        p16((u32)0);
        Pe.sectHdr(self, String.withCString(".text"), mtext.count(), textOff, trelOff, nTextRel,
                   (u32)COFF_SCN_CODE | (u32)$20000000 | (u32)$40000000 | (u32)$00500000);
        Pe.sectHdr(self, String.withCString(".data"), mdata.count(), dataOff, drelOff, nDataRel,
                   (u32)COFF_SCN_INIT_DATA | (u32)$40000000 | (u32)$80000000 | (u32)$00400000);
        for (u32 i = (u32)0; i < mtext.count(); i = i + (u32)1)
            _out.add(mtext.get(i));
        for (u32 i = (u32)0; i < mdata.count(); i = i + (u32)1)
            _out.add(mdata.get(i));
        for (u32 i = (u32)0; i < textRel.count(); i = i + (u32)1)
            _out.add(textRel.get(i));
        for (u32 i = (u32)0; i < dataRel.count(); i = i + (u32)1)
            _out.add(dataRel.get(i));
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            String* n = (String*)order.get(i);
            Object* val = symbols.get((Hashable*)n);
            bool isUndef = val == (Object*)0;
            bool inData = Pe.inArray(dataSyms, n);
            u32 sx = ((Number*)strx.get(i)).asU32();
            if (sx == (u32)0)
                {
                for (u32 b = (u32)0; b < (u32)8; b = b + (u32)1)
                    p8(b < n.byteLength() ? (u32)n.byteAt(b) : (u32)0);
                }
            else
                {
                p32((u32)0);
                p32(sx);
                }
            p32(isUndef ? (u32)0 : ((Number*)val).asU32());
            p16(isUndef ? (u32)0 : (inData ? (u32)2 : (u32)1));
            p16((u32)0);
            p8((isUndef || Pe.inArray(globalSyms, n)) ? (u32)2 : (u32)3);
            p8((u32)0);
            }
        for (u32 i = (u32)0; i < strtab.count(); i = i + (u32)1)
            _out.add(strtab.get(i));
        return _out;
        }
    static void rel(Array* into, u32 off, u32 si, u32 type)
        {
        for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
            into.add((Object*)Number.withU32((off >> (b * (u32)8)) & (u32)$FF));
        for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
            into.add((Object*)Number.withU32((si >> (b * (u32)8)) & (u32)$FF));
        into.add((Object*)Number.withU32(type & (u32)$FF));
        into.add((Object*)Number.withU32((type >> (u32)8) & (u32)$FF));
        }
    static void sectHdr(Pe* w, String* nm, u32 sz, u32 raw, u32 rl, u32 nrel, u32 chars)
        {
        for (u32 b = (u32)0; b < (u32)8; b = b + (u32)1)
            w.p8(b < nm.byteLength() ? (u32)nm.byteAt(b) : (u32)0);
        w.p32((u32)0);
        w.p32((u32)0);
        w.p32(sz);
        w.p32(sz != (u32)0 ? raw : (u32)0);
        w.p32(nrel != (u32)0 ? rl : (u32)0);
        w.p32((u32)0);
        w.p16(nrel);
        w.p16((u32)0);
        w.p32(chars);
        }

    void executable(Array* textIn, Array* dataIn, Map* symbols, Array* dataSyms,
                    Array* fixups, String* entrySymbol,
                    Array* importDlls, Array* importSyms)
        {
        Object* entry = symbols.get((Hashable*)entrySymbol);
        if (entry == (Object*)0 || inArray(dataSyms, entrySymbol))
            {
            failWith(String.withCString("entry symbol is not defined in the text section"),
                     entrySymbol);
            return;
            }
        _dllOrder = new Array();
        _usedSyms = new Array();
        _iatIndex = new Map();
        _iatSlot = new Map();
        _stubSym = new Array();
        _nImports = (u32)0;
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)fixups.get(i);
            // `__imp_X` is not a symbol in its own right — it is the ADDRESS
            // OF X's IAT slot, which is how a real toolchain's objects reach
            // an import they call indirectly (`call [rip + __imp_X]`) or
            // store. It needs X imported, resolves to the slot rather than a
            // stub, and is legitimately a DATA reference (bug 141: mingw's
            // snprintf reaches ucrtbase this way).
            String* viaImp = Pe.impTarget(f.symbol());
            String* want = viaImp != (String*)0 ? viaImp : f.symbol();
            if (symbols.get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            if (_iatIndex.get((Hashable*)want) != (Object*)0)
                continue;
            i32 owner = ownerOf(importDlls, importSyms, want);
            if (owner < (i32)0)
                {
                failWith(String.withCString("undefined symbol — it is neither defined here nor listed as a DLL import"),
                         f.symbol());
                return;
                }
            if (f.kind() != (u32)X86FIX_REL32 && viaImp == (String*)0)
                {
                failWith(String.withCString("undefined DATA symbol; only function imports are supported (a data import would need the referencing instruction rewritten to an indirection)"),
                         f.symbol());
                return;
                }
            String* dll = (String*)importDlls.get((u32)owner);
            // One descriptor per DLL, matched case-INSENSITIVELY: Windows loads
            // a library once however it is spelled, and two descriptors for
            // `kernel32.dll` and `KERNEL32.dll` (which an imports map and a
            // hand-written extern between them produce) double the IAT for
            // nothing. The first spelling seen is the one written.
            i32 slot = indexOfStringNoCase(_dllOrder, dll);
            if (slot < (i32)0)
                {
                _dllOrder.add((Object*)dll);
                _usedSyms.add((Object*)new Array());
                slot = (i32)(_dllOrder.count() - (u32)1);
                }
            ((Array*)_usedSyms.get((u32)slot)).add((Object*)want);
            _iatIndex.set((Hashable*)want, (Object*)Number.withU32(_nImports));
            _stubSym.add((Object*)want);
            _nImports = _nImports + (u32)1;
            }
            // A symbol's IAT SLOT is not its stub number. The IAT is written per
            // DLL with a null terminator after each, so slot n of the whole array
            // is not import n — every symbol of the second DLL sits one slot
            // further on than its discovery order suggests. Indexing by the stub
            // number was invisible while programs imported a single DLL, and made
            // the FIRST import of the second DLL resolve to the first DLL's
            // terminator: a `call` straight through a null IAT entry, to address 0.
            {
            u32 slotNo = (u32)0;
            for (u32 d = (u32)0; d < _dllOrder.count(); d = d + (u32)1)
                {
                Array* syms = (Array*)_usedSyms.get(d);
                for (u32 k = (u32)0; k < syms.count(); k = k + (u32)1)
                    {
                    _iatSlot.set((Hashable*)(String*)syms.get(k),
                                 (Object*)Number.withU32(slotNo));
                    slotNo = slotNo + (u32)1;
                    }
                slotNo = slotNo + (u32)1; // this DLL's terminator
                }
            }
        buildImage(copyBytes(textIn), copyBytes(dataIn), symbols, dataSyms, fixups,
                   ((Number*)entry).asU32());
        }

    static i32 indexOfStringNoCase(Array* a, String* want)
        {
        String* w = want.lowercased();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).lowercased().equals(w))
                return (i32)i;
        return (i32)-1;
        }

    // `importDlls[i]` names a DLL and `importSyms[i]` is the Array of symbols
    // taken from it, so the two run in parallel rather than needing a map of
    // arrays.
    static String* impTarget(String* n)
        {
        return n != (String*)0 && n.hasPrefix(String.withCString("__imp_")) ? n.substringFromByte((u32)6) : (String*)0;
        }
    static i32 ownerOf(Array* dlls, Array* syms, String* name)
        {
        for (u32 i = (u32)0; i < dlls.count(); i = i + (u32)1)
            if (inArray((Array*)syms.get(i), name))
                return (i32)i;
        return (i32)-1;
        }

    static i32 indexOfString(Array* a, String* s)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(s))
                return (i32)i;
        return (i32)-1;
        }

    // ── Layout ───────────────────────────────────────────────────────────
    //
    // Nothing below depends on an address, so the whole layout is fixed before
    // a byte is written.
    u32 _thunkOff;
    u32 _textLen;
    u32 _nDesc;
    u32 _descSz;
    u32 _iltSz;
    u32 _iatSz;
    u32 _nSect;
    u32 _hdrSz;
    u32 _textRVA;
    u32 _textRaw;
    u32 _rdataRVA;
    u32 _rdataRaw;
    u32 _descRVA;
    u32 _iltRVA;
    u32 _iatRVA;
    u32 _namesRVA;
    u32 _rdataLen;
    u32 _dataRVA;
    u32 _dataRaw;
    u32 _thunkRVA;
    u32 _dataFileSz;
    Map* _nameRVA; // imported symbol -> the RVA of its hint/name entry
    Map* _dllNameRVA;

    void buildImage(Array* text, Array* data, Map* symbols, Array* dataSyms,
                    Array* fixups, u32 entryOffset)
        {
        _thunkOff = text.count(); // the stubs append to .text
        _textLen = text.count() + _nImports * (u32)PE_THUNK_SZ;

        // .rdata holds the import machinery: descriptors, then per-DLL ILT and
        // IAT (two identical arrays — the loader overwrites the IAT), then the
        // hint/name entries, then the DLL name strings.
        _nDesc = _dllOrder.count() + (u32)1; // + the null terminator
        _descSz = _nDesc * (u32)20;
        u32 thunkArraySz = (u32)0;
        for (u32 i = (u32)0; i < _dllOrder.count(); i = i + (u32)1)
            thunkArraySz = thunkArraySz + (((Array*)_usedSyms.get(i)).count() + (u32)1) * (u32)8;
        _iltSz = thunkArraySz;
        _iatSz = thunkArraySz;

        _nSect = data.count() > (u32)0 ? (u32)3 : (u32)2;
        _hdrSz = alignUp((u32)$40 + (u32)$40 + (u32)4 + (u32)20 + (u32)PE_OPT_HDR_SIZE + _nSect * (u32)PE_SECT_HDR_SIZE, (u32)PE_FILE_ALIGN);
        _textRVA = (u32)PE_SECT_ALIGN;
        _textRaw = _hdrSz;
        _rdataRVA = alignUp(_textRVA + _textLen, (u32)PE_SECT_ALIGN);
        _rdataRaw = alignUp(_textRaw + _textLen, (u32)PE_FILE_ALIGN);
        _descRVA = _rdataRVA;
        _iltRVA = _descRVA + _descSz;
        _iatRVA = _iltRVA + _iltSz;
        _namesRVA = _iatRVA + _iatSz;

        // Hint/name entries: a u16 hint then the NUL-terminated name, 2-byte
        // aligned.
        _nameRVA = new Map();
        u32 cur = _namesRVA;
        for (u32 i = (u32)0; i < _dllOrder.count(); i = i + (u32)1)
            {
            Array* syms = (Array*)_usedSyms.get(i);
            for (u32 k = (u32)0; k < syms.count(); k = k + (u32)1)
                {
                String* sym = (String*)syms.get(k);
                _nameRVA.set((Hashable*)sym, (Object*)Number.withU32(cur));
                cur = alignUp(cur + (u32)2 + sym.byteLength() + (u32)1, (u32)2);
                }
            }
        _dllNameRVA = new Map();
        for (u32 i = (u32)0; i < _dllOrder.count(); i = i + (u32)1)
            {
            String* dll = (String*)_dllOrder.get(i);
            _dllNameRVA.set((Hashable*)dll, (Object*)Number.withU32(cur));
            cur = cur + dll.byteLength() + (u32)1;
            }
        _rdataLen = cur - _rdataRVA;
        _dataRVA = alignUp(_rdataRVA + _rdataLen, (u32)PE_SECT_ALIGN);
        _dataRaw = alignUp(_rdataRaw + _rdataLen, (u32)PE_FILE_ALIGN);
        _thunkRVA = _textRVA + _thunkOff;

        // Import stubs: jmp qword ptr [rip + IAT slot].
        for (u32 i = (u32)0; i < _nImports; i = i + (u32)1)
            {
            u32 here = _thunkRVA + i * (u32)PE_THUNK_SZ;
            u32 slotNo = ((Number*)_iatSlot.get((Hashable*)(String*)_stubSym.get(i))).asU32();
            i32 rel = (i32)(_iatRVA + slotNo * (u32)8) - (i32)(here + (u32)PE_THUNK_SZ);
            text.add((Object*)Number.withU32((u32)$FF));
            text.add((Object*)Number.withU32((u32)$25));
            for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                text.add((Object*)Number.withU32(((u32)rel >> ((u32)8 * k)) & (u32)$FF));
            }

        if (!resolveFixups(text, data, symbols, dataSyms, fixups))
            return;

        // Measure the file size AFTER patching: a vtable slot holding a
        // symbolic .quad was zero until the abs64 fixup wrote its address.
        // Measuring first would count it as a trailing zero, drop it from the
        // file, and the slot would read back null — a virtual call to zero.
        _dataFileSz = rawSizeOf(data);

        emitFile(text, data, entryOffset);
        }

    bool resolveFixups(Array* text, Array* data, Map* symbols, Array* dataSyms, Array* fixups)
        {
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)fixups.get(i);
            Object* off = symbols.get((Hashable*)f.symbol());
            String* viaImp = Pe.impTarget(f.symbol());
            u32 target;
            if (off != (Object*)0)
                target = (inArray(dataSyms, f.symbol()) ? _dataRVA : _textRVA) + ((Number*)off).asU32();
            else if (viaImp != (String*)0)
                target = _iatRVA + ((Number*)_iatSlot.get((Hashable*)viaImp)).asU32() * (u32)8;
            else
                target = _thunkRVA + ((Number*)_iatIndex.get((Hashable*)f.symbol())).asU32() * (u32)PE_THUNK_SZ;

            if (f.kind() == (u32)X86FIX_ABS64)
                {
                if (f.offset() + (u32)8 > data.count())
                    {
                    failWith(String.withCString("abs64 fixup past the end of data"), f.symbol());
                    return false;
                    }
                // A full virtual address, which is only correct if the image
                // really loads at ImageBase — hence DYNAMIC_BASE stays off.
                u32 lo = (u32)PE_BASE_LO + target + (u32)f.addend();
                u32 hi = (u32)PE_BASE_HI;
                if (lo < target)
                    hi = hi + (u32)1; // carry out of the low half
                for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                    data.set(f.offset() + k, (Object*)Number.withU32((lo >> ((u32)8 * k)) & (u32)$FF));
                for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                    data.set(f.offset() + (u32)4 + k,
                             (Object*)Number.withU32((hi >> ((u32)8 * k)) & (u32)$FF));
                continue;
                }
            if (f.offset() + (u32)4 > text.count())
                {
                failWith(String.withCString("pc32 fixup past the end of text"), f.symbol());
                return false;
                }
            // Both sides carry ImageBase, so it cancels and this is RVA
            // arithmetic.
            i32 rel = (i32)target - (i32)(_textRVA + f.offset()) + f.addend();
            for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                text.set(f.offset() + k, (Object*)Number.withU32(((u32)rel >> ((u32)8 * k)) & (u32)$FF));
            }
        return true;
        }

    void emitFile(Array* text, Array* data, u32 entryOffset)
        {
        // DOS header. Windows does not care about the stub, but it must be
        // there and e_lfanew must point PAST it — pointing at 0x40 puts the
        // stub where the PE header is claimed to be, and the loader spins on
        // the garbage it finds.
        p8((u32)'M');
        p8((u32)'Z');
        for (u32 i = (u32)2; i < (u32)$3C; i = i + (u32)1)
            p8((u32)0);
        p32((u32)$80);
        emitDosStub();
        padTo((u32)$80);

        p32((u32)$00004550); // "PE\0\0"
        p16((u32)$8664);     // AMD64
        p16(_nSect);
        p32((u32)0); // TimeDateStamp — 0 keeps
        p32((u32)0); //   the output reproducible
        p32((u32)0); // NumberOfSymbols
        p16((u32)PE_OPT_HDR_SIZE);
        p16((u32)$0002 | (u32)$0020); // EXECUTABLE | LARGE_ADDRESS

        // Optional header (PE32+).
        p16((u32)$20B);
        p8((u32)14);
        p8((u32)0);                                 // linker version
        p32(alignUp(_textLen, (u32)PE_FILE_ALIGN)); // SizeOfCode
        p32(alignUp(_rdataLen + _dataFileSz, (u32)PE_FILE_ALIGN));
        p32((u32)0);                           // SizeOfUninitializedData
        p32(_textRVA + entryOffset);           // AddressOfEntryPoint
        p32(_textRVA);                         // BaseOfCode
        p64((u32)PE_BASE_LO, (u32)PE_BASE_HI); // ImageBase
        p32((u32)PE_SECT_ALIGN);
        p32((u32)PE_FILE_ALIGN);
        p16((u32)6);
        p16((u32)0); // OS version 6.0
        p16((u32)0);
        p16((u32)0); // image version
        p16((u32)6);
        p16((u32)0); // subsystem version 6.0
        p32((u32)0); // Win32VersionValue
        u32 sizeOfImage = alignUp(data.count() > (u32)0 ? _dataRVA + data.count()
                                                        : _rdataRVA + _rdataLen,
                                  (u32)PE_SECT_ALIGN);
        p32(sizeOfImage);
        p32(_hdrSz);
        p32((u32)0); // CheckSum — only DLLs need one
        p16((u32)3); // console subsystem
        p16((u32)0); // no DYNAMIC_BASE, so ImageBase holds
        p64((u32)$100000, (u32)0);
        p64((u32)$1000, (u32)0); // stack reserve / commit
        p64((u32)$100000, (u32)0);
        p64((u32)$1000, (u32)0); // heap  reserve / commit
        p32((u32)0);             // LoaderFlags
        p32((u32)16);            // NumberOfRvaAndSizes
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            {
            if (i == (u32)1 && _nImports != (u32)0)
                {
                p32(_descRVA);
                p32(_descSz);
                }
            else if (i == (u32)12 && _nImports != (u32)0)
                {
                p32(_iatRVA);
                p32(_iatSz);
                }
            else
                {
                p32((u32)0);
                p32((u32)0);
                }
            }

        sect(String.withCString(".text"), _textLen, _textRVA, _textLen, _textRaw,
             (u32)$20 | (u32)$20000000 | (u32)$40000000);
        sect(String.withCString(".rdata"), _rdataLen, _rdataRVA, _rdataLen, _rdataRaw,
             (u32)$40 | (u32)$40000000);
        if (data.count() > (u32)0)
            sect(String.withCString(".data"), data.count(), _dataRVA, _dataFileSz, _dataRaw,
                 (u32)$40 | (u32)$40000000 | (u32)$80000000);

        padTo(_textRaw);
        appendAll(text);
        padTo(_rdataRaw);
        emitImportTables();
        if (data.count() > (u32)0)
            {
            padTo(_dataRaw);
            for (u32 i = (u32)0; i < _dataFileSz; i = i + (u32)1)
                _out.add(data.get(i));
            }
        // Every section's raw data is FileAlignment-padded; a short final
        // section makes some loaders reject the image.
        while (_out.count() % (u32)PE_FILE_ALIGN != (u32)0)
            p8((u32)0);
        }

    // A stub that prints the usual message if the program is run under DOS.
    void emitDosStub(void)
        {
        p8((u32)$0E);
        p8((u32)$1F);
        p8((u32)$BA);
        p8((u32)$0E);
        p8((u32)$00);
        p8((u32)$B4);
        p8((u32)$09);
        p8((u32)$CD);
        p8((u32)$21);
        p8((u32)$B8);
        p8((u32)$01);
        p8((u32)$4C);
        p8((u32)$CD);
        p8((u32)$21);
        String* msg = String.withCString("This program cannot be run in DOS mode.");
        for (u32 i = (u32)0; i < msg.byteLength(); i = i + (u32)1)
            p8((u32)msg.byteAt(i));
        p8((u32)13);
        p8((u32)13);
        p8((u32)10);
        p8((u32)'$');
        }

    void sect(String* nm, u32 vsize, u32 rva, u32 rawsz, u32 rawptr, u32 chars)
        {
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            p8(i < nm.byteLength() ? (u32)nm.byteAt(i) : (u32)0);
        p32(vsize);
        p32(rva);
        p32(alignUp(rawsz, (u32)PE_FILE_ALIGN));
        p32(rawptr);
        p32((u32)0);
        p32((u32)0);
        p16((u32)0);
        p16((u32)0);
        p32(chars);
        }

    void emitImportTables(void)
        {
        u32 iltCur = _iltRVA;
        u32 iatCur = _iatRVA;
        for (u32 i = (u32)0; i < _dllOrder.count(); i = i + (u32)1)
            {
            String* dll = (String*)_dllOrder.get(i);
            Array* syms = (Array*)_usedSyms.get(i);
            p32(iltCur); // OriginalFirstThunk (ILT)
            p32((u32)0);
            p32((u32)0); // TimeDateStamp, ForwarderChain
            p32(((Number*)_dllNameRVA.get((Hashable*)dll)).asU32());
            p32(iatCur); // FirstThunk (IAT)
            iltCur = iltCur + (syms.count() + (u32)1) * (u32)8;
            iatCur = iatCur + (syms.count() + (u32)1) * (u32)8;
            }
        for (u32 i = (u32)0; i < (u32)5; i = i + (u32)1)
            p32((u32)0); // null descriptor

        // The ILT and the IAT are identical on disk; the loader replaces the
        // IAT in memory.
        for (u32 pass = (u32)0; pass < (u32)2; pass = pass + (u32)1)
            for (u32 i = (u32)0; i < _dllOrder.count(); i = i + (u32)1)
                {
                Array* syms = (Array*)_usedSyms.get(i);
                for (u32 k = (u32)0; k < syms.count(); k = k + (u32)1)
                    p64(((Number*)_nameRVA.get((Hashable*)(String*)syms.get(k))).asU32(), (u32)0);
                p64((u32)0, (u32)0); // terminator
                }
        for (u32 i = (u32)0; i < _dllOrder.count(); i = i + (u32)1)
            {
            Array* syms = (Array*)_usedSyms.get(i);
            for (u32 k = (u32)0; k < syms.count(); k = k + (u32)1)
                {
                String* sym = (String*)syms.get(k);
                p16((u32)0); // hint 0 means "search by name"
                for (u32 c = (u32)0; c < sym.byteLength(); c = c + (u32)1)
                    p8((u32)sym.byteAt(c));
                p8((u32)0);
                if ((_out.count() & (u32)1) != (u32)0)
                    p8((u32)0); // 2-byte aligned
                }
            }
        for (u32 i = (u32)0; i < _dllOrder.count(); i = i + (u32)1)
            {
            String* dll = (String*)_dllOrder.get(i);
            for (u32 c = (u32)0; c < dll.byteLength(); c = c + (u32)1)
                p8((u32)dll.byteAt(c));
            p8((u32)0);
            }
        }

    void appendAll(Array* a)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            _out.add(a.get(i));
        }
    }
