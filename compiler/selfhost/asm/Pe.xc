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
#import "Files.xc"

#define PE_FILE_ALIGN $200
#define PE_SECT_ALIGN $1000
#define PE_OPT_HDR_SIZE 240
#define PE_SECT_HDR_SIZE 40
#define PE_THUNK_SZ 6
#define PE_BASE_LO $40000000
#define PE_DLL_BASE_LO $80000000
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
        _isDll = false;
        _baseLo = (u32)PE_BASE_LO;
        link(textIn, dataIn, symbols, dataSyms, fixups, entrySymbol, importDlls, importSyms);
        }

    // The same inputs as a DLL named `dllName` (bug 255): IMAGE_FILE_DLL, a
    // relocatable ImageBase with a `.reloc` section for every absolute data
    // word, an export directory naming every defined name in `globals` (the
    // `.globl` names), and the interface, when there is one, in an `xtciface`
    // section. `entrySymbol` is the DllMain the loader calls. Mirrors
    // XTPEWriter's dllFromText.
    void dll(Array* textIn, Array* dataIn, Map* symbols, Array* dataSyms,
             Array* fixups, String* entrySymbol,
             Array* importDlls, Array* importSyms,
             String* dllName, Array* globals, Data* iface)
        {
        _isDll = true;
        _baseLo = (u32)PE_DLL_BASE_LO;
        _dllName = dllName;
        _iface = iface;
        // Every defined `.globl` name, in byte order (the loader binary-searches
        // the name pointer table). The constructor-table bounds stay private,
        // as they do in an ELF library.
        _exports = new Array();
        Map* seen = new Map();
        for (u32 i = (u32)0; globals != (Array*)0 && i < globals.count(); i = i + (u32)1)
            {
            String* n = (String*)globals.get(i);
            if (symbols.get((Hashable*)n) == (Object*)0)
                continue;
            if (n.equals(String.withCString("__xt_ctors_start")) || n.equals(String.withCString("__xt_ctors_end")))
                continue;
            if (seen.get((Hashable*)n) != (Object*)0)
                continue;
            seen.set((Hashable*)n, (Object*)n);
            _exports.add((Object*)n);
            }
        Pe.sortStrings(_exports);
        link(textIn, dataIn, symbols, dataSyms, fixups, entrySymbol, importDlls, importSyms);
        }

    bool _isDll;
    u32 _baseLo; // ImageBase's low half; the high half is PE_BASE_HI either way
    String* _dllName;
    Data* _iface;
    Array* _exports;

    void link(Array* textIn, Array* dataIn, Map* symbols, Array* dataSyms,
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
            // A call reaches an import through its stub, a `lea` through its
            // IAT slot, and a data word through a pseudo-relocation. Nothing
            // else can reach one.
            if (f.kind() != (u32)X86FIX_REL32 && f.kind() != (u32)X86FIX_PC32
                && f.kind() != (u32)X86FIX_ABS64 && viaImp == (String*)0)
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

    // Offsets in ascending order (the base-relocation blocks are per page).
    static void sortU32(Array* a)
        {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1)
            {
            Object* v = a.get(i);
            u32 key = ((Number*)v).asU32();
            u32 j = i;
            while (j > (u32)0 && ((Number*)a.get(j - (u32)1)).asU32() > key)
                {
                a.set(j, a.get(j - (u32)1));
                j = j - (u32)1;
                }
            a.set(j, v);
            }
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
    // The pseudo-relocation stub, the export directory, and the DLL-only
    // sections after .data.
    Array* _pseudo; // X86Fixup@: the data words naming an import
    u32 _stubOff;
    u32 _stubSz;
    u32 _entryRVA;
    u32 _expRVA;
    u32 _expEnd;
    u32 _eatRVA;
    u32 _nptRVA;
    u32 _ordRVA;
    u32 _expNamesRVA;
    u32 _expDllNameRVA;
    Array* _relocOffs; // Number@: data offsets of words needing a base relocation
    Array* _reloc;     // Number@: the .reloc bytes
    bool _hasIface;
    u32 _ifaceRVA;
    u32 _ifaceRaw;
    u32 _relocRVA;
    u32 _relocRaw;
    u32 _afterRVA;

    void buildImage(Array* text, Array* data, Map* symbols, Array* dataSyms,
                    Array* fixups, u32 entryOffset)
        {
        // Data words naming an import: each is filled at startup from the
        // import's IAT slot by the stub in front of the entry point.
        _pseudo = new Array();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)fixups.get(i);
            if (f.kind() == (u32)X86FIX_ABS64 && symbols.get((Hashable*)f.symbol()) == (Object*)0
                && Pe.impTarget(f.symbol()) == (String*)0)
                _pseudo.add((Object*)f);
            }
        _thunkOff = text.count(); // the stubs append to .text
        // The pseudo-relocation stub: in a DLL `cmp edx, 1; jne entry` first
        // (the loader calls the entry again for every thread and at unload),
        // then per word `mov rax, [rip + slot]; add [rip + word], rax`, then
        // `jmp entry`.
        _stubOff = _thunkOff + _nImports * (u32)PE_THUNK_SZ;
        _stubSz = (u32)0;
        if (_pseudo.count() > (u32)0)
            _stubSz = (_isDll ? (u32)9 : (u32)0) + _pseudo.count() * (u32)14 + (u32)5;
        _textLen = text.count() + _nImports * (u32)PE_THUNK_SZ + _stubSz;

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

        // Base relocations: every absolute data word whose target is in this
        // image. A word a pseudo-relocation fills is not one — the IAT value it
        // takes is already the final address.
        _relocOffs = new Array();
        if (_isDll)
            {
            for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
                {
                X86Fixup* f = (X86Fixup*)fixups.get(i);
                if (f.kind() == (u32)X86FIX_ABS64
                    && (symbols.get((Hashable*)f.symbol()) != (Object*)0 || Pe.impTarget(f.symbol()) != (String*)0))
                    _relocOffs.add((Object*)Number.withU32(f.offset()));
                }
            Pe.sortU32(_relocOffs);
            }
        _hasIface = _isDll && _iface != (Data*)0 && _iface.length() > (u32)0;

        _nSect = (data.count() > (u32)0 ? (u32)3 : (u32)2) + (_hasIface ? (u32)1 : (u32)0)
                 + (_relocOffs.count() > (u32)0 ? (u32)1 : (u32)0);
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
        // The export directory follows, 4-aligned: the directory table, the
        // address table, the name pointer table, the ordinal table, the names,
        // and the DLL's own name. Address i and name i are the same symbol, so
        // ordinal i is simply i.
        if (_isDll)
            {
            u32 ne = _exports.count();
            _expRVA = alignUp(cur, (u32)4);
            _eatRVA = _expRVA + (u32)40;
            _nptRVA = _eatRVA + ne * (u32)4;
            _ordRVA = _nptRVA + ne * (u32)4;
            _expNamesRVA = _ordRVA + ne * (u32)2;
            u32 e = _expNamesRVA;
            for (u32 i = (u32)0; i < ne; i = i + (u32)1)
                e = e + ((String*)_exports.get(i)).byteLength() + (u32)1;
            _expDllNameRVA = e;
            _expEnd = e + _dllName.byteLength() + (u32)1;
            cur = _expEnd;
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

        // The pseudo-relocation stub.
        _entryRVA = _textRVA + entryOffset;
        if (_pseudo.count() > (u32)0)
            {
            if (_isDll)
                {
                Pe.b3(text, (u32)$83, (u32)$FA, (u32)$01); // cmp edx, 1 (DLL_PROCESS_ATTACH)
                text.add((Object*)Number.withU32((u32)$0F));
                text.add((Object*)Number.withU32((u32)$85)); // jne entry
                ripRel(text, _entryRVA);
                }
            for (u32 i = (u32)0; i < _pseudo.count(); i = i + (u32)1)
                {
                X86Fixup* f = (X86Fixup*)_pseudo.get(i);
                Pe.b3(text, (u32)$48, (u32)$8B, (u32)$05); // mov rax, [rip + slot]
                ripRel(text, _iatRVA + ((Number*)_iatSlot.get((Hashable*)f.symbol())).asU32() * (u32)8);
                Pe.b3(text, (u32)$48, (u32)$01, (u32)$05); // add [rip + word], rax
                ripRel(text, _dataRVA + f.offset());
                }
            text.add((Object*)Number.withU32((u32)$E9)); // jmp entry
            ripRel(text, _entryRVA);
            }

        if (!resolveFixups(text, data, symbols, dataSyms, fixups))
            return;

        // Measure the file size AFTER patching: a vtable slot holding a
        // symbolic .quad was zero until the abs64 fixup wrote its address.
        // Measuring first would count it as a trailing zero, drop it from the
        // file, and the slot would read back null — a virtual call to zero.
        _dataFileSz = rawSizeOf(data);

        // The DLL-only sections after .data: the interface, then the
        // relocations.
        _afterRVA = data.count() > (u32)0 ? _dataRVA + data.count() : _rdataRVA + _rdataLen;
        u32 afterRaw = data.count() > (u32)0 ? _dataRaw + alignUp(_dataFileSz, (u32)PE_FILE_ALIGN)
                                             : _rdataRaw + alignUp(_rdataLen, (u32)PE_FILE_ALIGN);
        if (_hasIface)
            {
            _ifaceRVA = alignUp(_afterRVA, (u32)PE_SECT_ALIGN);
            _ifaceRaw = afterRaw;
            _afterRVA = _ifaceRVA + _iface.length();
            afterRaw = _ifaceRaw + alignUp(_iface.length(), (u32)PE_FILE_ALIGN);
            }
        // One block per 4 KB page: {page RVA, block size}, then a u16 per word
        // — type 10 (DIR64) in the top four bits, the offset in the page below
        // — padded to a multiple of four with an absolute (type 0) entry.
        _reloc = new Array();
        u32 i = (u32)0;
        while (i < _relocOffs.count())
            {
            u32 page = (_dataRVA + ((Number*)_relocOffs.get(i)).asU32()) & ~(u32)$FFF;
            u32 j = i;
            while (j < _relocOffs.count()
                   && ((_dataRVA + ((Number*)_relocOffs.get(j)).asU32()) & ~(u32)$FFF) == page)
                j = j + (u32)1;
            u32 n = j - i;
            Pe.put32(_reloc, page);
            Pe.put32(_reloc, (u32)8 + (n + (n & (u32)1)) * (u32)2);
            for (u32 k = i; k < j; k = k + (u32)1)
                {
                u32 e = (u32)$A000 | ((_dataRVA + ((Number*)_relocOffs.get(k)).asU32()) & (u32)$FFF);
                _reloc.add((Object*)Number.withU32(e & (u32)$FF));
                _reloc.add((Object*)Number.withU32((e >> (u32)8) & (u32)$FF));
                }
            if ((n & (u32)1) != (u32)0)
                {
                _reloc.add((Object*)Number.withU32((u32)0));
                _reloc.add((Object*)Number.withU32((u32)0));
                }
            i = j;
            }
        if (_reloc.count() > (u32)0)
            {
            _relocRVA = alignUp(_afterRVA, (u32)PE_SECT_ALIGN);
            _relocRaw = afterRaw;
            _afterRVA = _relocRVA + _reloc.count();
            }

        emitFile(text, data, symbols, dataSyms);
        }

    static void b3(Array* a, u32 x, u32 y, u32 z)
        {
        a.add((Object*)Number.withU32(x));
        a.add((Object*)Number.withU32(y));
        a.add((Object*)Number.withU32(z));
        }
    static void put32(Array* a, u32 v)
        {
        for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
            a.add((Object*)Number.withU32((v >> ((u32)8 * k)) & (u32)$FF));
        }
    // The rel32 of an instruction whose displacement is its last four bytes,
    // appended at the end of `text`.
    void ripRel(Array* text, u32 targetRVA)
        {
        i32 r = (i32)targetRVA - (i32)(_textRVA + text.count() + (u32)4);
        Pe.put32(text, (u32)r);
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
            else if (f.kind() == (u32)X86FIX_ABS64)
                {
                // A pseudo-relocation: the word holds the addend until the stub
                // adds the import's address to it.
                if (f.offset() + (u32)8 > data.count())
                    {
                    failWith(String.withCString("abs64 fixup past the end of data"), f.symbol());
                    return false;
                    }
                u32 lo = (u32)f.addend();
                u32 hi = f.addend() < (i32)0 ? (u32)$FFFF_FFFF : (u32)0;
                for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                    data.set(f.offset() + k, (Object*)Number.withU32((lo >> ((u32)8 * k)) & (u32)$FF));
                for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                    data.set(f.offset() + (u32)4 + k,
                             (Object*)Number.withU32((hi >> ((u32)8 * k)) & (u32)$FF));
                continue;
                }
            else if (f.kind() == (u32)X86FIX_PC32)
                {
                // `lea reg, [rip + import]` becomes `mov reg, [rip + slot]`:
                // REX.W, 8D -> 8B, and a ModRM of [rip + disp32]. Anything else
                // would need a longer instruction.
                u32 o = f.offset();
                bool isLea = o >= (u32)3 && o + (u32)4 <= text.count()
                             && (((Number*)text.get(o - (u32)3)).asU32() & (u32)$F8) == (u32)$48
                             && ((Number*)text.get(o - (u32)2)).asU32() == (u32)$8D
                             && (((Number*)text.get(o - (u32)1)).asU32() & (u32)$C7) == (u32)$05
                             && f.addend() == (i32)-4;
                if (!isLea)
                    {
                    failWith(String.withCString("an imported symbol reached by an instruction other than `lea` (only a `lea` can be rewritten to load the address from the import table)"),
                             f.symbol());
                    return false;
                    }
                text.set(o - (u32)2, (Object*)Number.withU32((u32)$8B));
                target = _iatRVA + ((Number*)_iatSlot.get((Hashable*)f.symbol())).asU32() * (u32)8;
                }
            else
                target = _thunkRVA + ((Number*)_iatIndex.get((Hashable*)f.symbol())).asU32() * (u32)PE_THUNK_SZ;

            if (f.kind() == (u32)X86FIX_ABS64)
                {
                if (f.offset() + (u32)8 > data.count())
                    {
                    failWith(String.withCString("abs64 fixup past the end of data"), f.symbol());
                    return false;
                    }
                // A full virtual address. An executable keeps DYNAMIC_BASE off
                // so ImageBase holds; a DLL carries a base relocation for it.
                u32 lo = _baseLo + target + (u32)f.addend();
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

    void emitFile(Array* text, Array* data, Map* symbols, Array* dataSyms)
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
        p16((u32)$0002 | (u32)$0020 | (_isDll ? (u32)$2000 : (u32)0)); // EXECUTABLE | LARGE_ADDRESS [| DLL]

        u32 ifaceLen = _hasIface ? _iface.length() : (u32)0;
        // Optional header (PE32+).
        p16((u32)$20B);
        p8((u32)14);
        p8((u32)0);                                 // linker version
        p32(alignUp(_textLen, (u32)PE_FILE_ALIGN)); // SizeOfCode
        p32(alignUp(_rdataLen + _dataFileSz + ifaceLen + _reloc.count(), (u32)PE_FILE_ALIGN));
        p32((u32)0);                           // SizeOfUninitializedData
        p32(_pseudo.count() > (u32)0 ? _textRVA + _stubOff : _entryRVA); // AddressOfEntryPoint
        p32(_textRVA);                         // BaseOfCode
        p64(_baseLo, (u32)PE_BASE_HI);         // ImageBase
        p32((u32)PE_SECT_ALIGN);
        p32((u32)PE_FILE_ALIGN);
        p16((u32)6);
        p16((u32)0); // OS version 6.0
        p16((u32)0);
        p16((u32)0); // image version
        p16((u32)6);
        p16((u32)0); // subsystem version 6.0
        p32((u32)0); // Win32VersionValue
        p32(alignUp(_afterRVA, (u32)PE_SECT_ALIGN)); // SizeOfImage
        p32(_hdrSz);
        p32((u32)0); // CheckSum — only drivers and boot-time DLLs need one
        p16((u32)3); // console subsystem
        // An executable leaves DYNAMIC_BASE off, so ImageBase holds. A DLL is
        // relocatable: DYNAMIC_BASE | HIGH_ENTROPY_VA | NX_COMPAT.
        p16(_isDll ? (u32)$0160 : (u32)0);
        p64((u32)$100000, (u32)0);
        p64((u32)$1000, (u32)0); // stack reserve / commit
        p64((u32)$100000, (u32)0);
        p64((u32)$1000, (u32)0); // heap  reserve / commit
        p32((u32)0);             // LoaderFlags
        p32((u32)16);            // NumberOfRvaAndSizes
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            {
            if (i == (u32)0 && _isDll)
                {
                p32(_expRVA);
                p32(_expEnd - _expRVA);
                }
            else if (i == (u32)1 && _nImports != (u32)0)
                {
                p32(_descRVA);
                p32(_descSz);
                }
            else if (i == (u32)5 && _reloc.count() > (u32)0)
                {
                p32(_relocRVA);
                p32(_reloc.count());
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
        // The interface is read out of the FILE by a compiler, never by the
        // program, so the loader may discard it.
        if (_hasIface)
            sect(String.withCString("xtciface"), ifaceLen, _ifaceRVA, ifaceLen, _ifaceRaw,
                 (u32)$40 | (u32)$40000000 | (u32)$02000000);
        if (_reloc.count() > (u32)0)
            sect(String.withCString(".reloc"), _reloc.count(), _relocRVA, _reloc.count(), _relocRaw,
                 (u32)$40 | (u32)$40000000 | (u32)$02000000);

        padTo(_textRaw);
        appendAll(text);
        padTo(_rdataRaw);
        emitImportTables();
        if (_isDll)
            emitExports(symbols, dataSyms);
        if (data.count() > (u32)0)
            {
            padTo(_dataRaw);
            for (u32 i = (u32)0; i < _dataFileSz; i = i + (u32)1)
                _out.add(data.get(i));
            }
        if (_hasIface)
            {
            padTo(_ifaceRaw);
            for (u32 i = (u32)0; i < ifaceLen; i = i + (u32)1)
                p8((u32)_iface.byteAt(i));
            }
        if (_reloc.count() > (u32)0)
            {
            padTo(_relocRaw);
            appendAll(_reloc);
            }
        // Every section's raw data is FileAlignment-padded; a short final
        // section makes some loaders reject the image.
        while (_out.count() % (u32)PE_FILE_ALIGN != (u32)0)
            p8((u32)0);
        }

    void emitExports(Map* symbols, Array* dataSyms)
        {
        padTo(_rdataRaw + (_expRVA - _rdataRVA));
        u32 ne = _exports.count();
        p32((u32)0); // ExportFlags
        p32((u32)0); // TimeDateStamp
        p16((u32)0);
        p16((u32)0); // version
        p32(_expDllNameRVA);
        p32((u32)1); // OrdinalBase
        p32(ne);
        p32(ne);
        p32(_eatRVA);
        p32(_nptRVA);
        p32(_ordRVA);
        for (u32 i = (u32)0; i < ne; i = i + (u32)1)
            {
            String* n = (String*)_exports.get(i);
            p32((inArray(dataSyms, n) ? _dataRVA : _textRVA)
                + ((Number*)symbols.get((Hashable*)n)).asU32());
            }
        u32 nm = _expNamesRVA;
        for (u32 i = (u32)0; i < ne; i = i + (u32)1)
            {
            p32(nm);
            nm = nm + ((String*)_exports.get(i)).byteLength() + (u32)1;
            }
        for (u32 i = (u32)0; i < ne; i = i + (u32)1)
            p16(i);
        for (u32 i = (u32)0; i < ne; i = i + (u32)1)
            {
            String* n = (String*)_exports.get(i);
            for (u32 c = (u32)0; c < n.byteLength(); c = c + (u32)1)
                p8((u32)n.byteAt(c));
            p8((u32)0);
            }
        for (u32 c = (u32)0; c < _dllName.byteLength(); c = c + (u32)1)
            p8((u32)_dllName.byteAt(c));
        p8((u32)0);
        }

    // The names a DLL exports, in its name-pointer-table order — the client
    // side of a DLL link, which needs no import library. Null when the file is
    // not a PE32+ image with an export directory. Mirrors XTPEWriter's
    // exportNamesOfDLL.
    static Array* dllExports(String* path)
        {
        Data* d = Files.readData(path);
        if (d == (Data*)0)
            return (Array*)0;
        u32 n = d.length();
        if (n < (u32)$40 || d.byteAt((u32)0) != (u8)'M' || d.byteAt((u32)1) != (u8)'Z')
            return (Array*)0;
        u32 pe = Pe.le32(d, (u32)$3C);
        if (Pe.le32(d, pe) != (u32)$00004550 || Pe.le16(d, pe + (u32)24) != (u32)$20B)
            return (Array*)0;
        u32 nsect = Pe.le16(d, pe + (u32)6);
        u32 opt = pe + (u32)24;
        u32 secTab = opt + Pe.le16(d, pe + (u32)20);
        u32 expRVA = Pe.le32(d, opt + (u32)112); // data directory 0 in a PE32+ header
        if (expRVA == (u32)0)
            return (Array*)0;
        i32 e = Pe.fileOff(d, nsect, secTab, expRVA);
        if (e < (i32)0)
            return (Array*)0;
        u32 nNames = Pe.le32(d, (u32)e + (u32)24);
        i32 npt = Pe.fileOff(d, nsect, secTab, Pe.le32(d, (u32)e + (u32)32));
        if (npt < (i32)0)
            return (Array*)0;
        Array* out = new Array();
        for (u32 i = (u32)0; i < nNames; i = i + (u32)1)
            {
            i32 s = Pe.fileOff(d, nsect, secTab, Pe.le32(d, (u32)npt + (u32)4 * i));
            if (s < (i32)0)
                return (Array*)0;
            String* nm = new String();
            u32 k = (u32)s;
            while (k < n && d.byteAt(k) != (u8)0)
                {
                nm.appendByte(d.byteAt(k));
                k = k + (u32)1;
                }
            out.add((Object*)nm);
            }
        return out;
        }

    static i32 fileOff(Data* d, u32 nsect, u32 secTab, u32 rva)
        {
        for (u32 i = (u32)0; i < nsect; i = i + (u32)1)
            {
            u32 s = secTab + i * (u32)PE_SECT_HDR_SIZE;
            u32 va = Pe.le32(d, s + (u32)12);
            u32 vsz = Pe.le32(d, s + (u32)8);
            u32 raw = Pe.le32(d, s + (u32)20);
            if (rva >= va && rva < va + vsz)
                return (i32)(raw + (rva - va));
            }
        return (i32)-1;
        }
    static u32 le16(Data* d, u32 at)
        {
        if (at + (u32)2 > d.length())
            return (u32)0;
        return (u32)d.byteAt(at) | ((u32)d.byteAt(at + (u32)1) << (u32)8);
        }
    static u32 le32(Data* d, u32 at)
        {
        if (at + (u32)4 > d.length())
            return (u32)0;
        return (u32)d.byteAt(at) | ((u32)d.byteAt(at + (u32)1) << (u32)8)
             | ((u32)d.byteAt(at + (u32)2) << (u32)16) | ((u32)d.byteAt(at + (u32)3) << (u32)24);
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
