// PeLink.xc — merge COFF objects and pull archive members into the x86-64
// assembler's own model for a win64 link. The mirror of xtcln-win64's
// mergeCoffObject and its archive fixpoint (bug 141: the shipped driver's
// win64 link took no objects, no archives and had no C-runtime pool, so a
// program needing `snprintf` could not link and one that did not still
// came out different from the reference).

#import "Foundation.xc"
#import <X86Asm>
#import <SectionBytes>
#import "X86AsmDefs.xc"
#import <CoffObject>
#import "CoffObjectDefs.xc"
#import <ArArchive>
#import <ElfObject>

class PeLink
    {
    String* _why;
    u32 _rc;
    SectionBytes* _pdata; // the objects' .pdata, one table (the exception directory)
    Array* _pdataFix;     // X86Fixup@ against it
    SectionBytes* _tls;   // the objects' .tls$ sections: the thread-local template
    Array* _tlsFix;       // X86Fixup@ against it
    Map* _tlsSyms;        // name -> Number(offset in _tls), defined when placed
    SectionBytes* _ctors; // the objects' .ctors: constructors, run by __main
    Array* _ctorsFix;     // X86Fixup@ against it

    void init(void)
        {
        _rc = (u32)0;
        _pdata = new SectionBytes();
        _pdataFix = new Array();
        _tls = new SectionBytes();
        _tlsFix = new Array();
        _tlsSyms = new Map();
        _ctors = new SectionBytes();
        _ctorsFix = new Array();
        }
    u32 rc(void)
        {
        return _rc;
        }
    String* why(void)
        {
        return _why;
        }

    void fail(String* m)
        {
        if (_rc == (u32)0)
            {
            _rc = (u32)1;
            _why = m;
            }
        }

    // A symbol reference in a pulled object: its real name if external or
    // undefined, a per-object-unique `name$o<oi>` if a LOCAL definition.
    static String* tagged(ElfSymDef* sd, u32 oi)
        {
        if (sd.ext() || sd.where() == (u32)0)
            return sd.name();
        String* t = String.withString(sd.name());
        t.appendCString("$o");
        t.append(Number.withU32(oi).description());
        return t;
        }
    // As tagged, for the symbol at index si of its object's table: a section
    // symbol (.rdata, .text$f) also carries its index, because one object
    // has many sections of one name (-ffunction-sections gives each jump
    // table its own .rdata), and under one tag every reference would reach
    // the first of them.
    static String* taggedAt(ElfSymDef* sd, u32 oi, u32 si)
        {
        String* t = PeLink.tagged(sd, oi);
        if (!sd.ext() && sd.where() != (u32)0 && sd.name().hasPrefix(String.withCString(".")))
            {
            t.appendCString("$");
            t.append(Number.withU32(si).description());
            }
        return t;
        }

    static void padArray(SectionBytes* a, u32 mask)
        {
        while ((a.length() & mask) != (u32)0)
            a.appendByte((u8)0);
        }
    static void appendData(SectionBytes* a, Data* d)
        {
        a.appendData(d);
        }

    // One object into the image. Text 16-aligned, data 8-aligned; first
    // definition wins except for the category-chain tables (§4.3b), where a
    // duplicate is a wrong CALL and is refused.
    bool mergeOne(CoffObject* obj, String* whence, u32 oi,
                  SectionBytes* mtext, SectionBytes* mdata, Map* msyms, Array* mdataSyms, Array* mfix)
        {
        PeLink.padArray(mtext, (u32)15);
        u32 tbase = mtext.length();
        PeLink.appendData(mtext, obj.text());
        u32 dbase = mdata.length();
        if (obj.data().length() > (u32)0)
            {
            PeLink.padArray(mdata, obj.dataAlign() - (u32)1);
            dbase = mdata.length();
            PeLink.appendData(mdata, obj.data());
            }
        u32 tlbase = _tls.length();
        if (obj.tls().length() > (u32)0)
            {
            PeLink.padArray(_tls, (u32)15);
            tlbase = _tls.length();
            PeLink.appendData(_tls, obj.tls());
            }
        Array* sdefs = obj.symdefs();
        for (u32 si = (u32)0; si < sdefs.count(); si = si + (u32)1)
            {
            ElfSymDef* sd = (ElfSymDef*)sdefs.get(si);
            if (sd.where() == (u32)0 || sd.name().byteLength() == (u32)0)
                continue;
            String* nm = PeLink.taggedAt(sd, oi, si);
            if (sd.where() == (u32)3)
                {
                // A thread-local: in the template, defined when it is placed.
                if (_tlsSyms.get((Hashable*)nm) == (Object*)0 && msyms.get((Hashable*)nm) == (Object*)0)
                    _tlsSyms.set((Hashable*)nm, (Object*)Number.withU32(tlbase + sd.off()));
                continue;
                }
            if (msyms.get((Hashable*)nm) != (Object*)0)
                {
                u32 catAt = PeLink.indexOf(nm, String.withCString("$cat$"));
                if (catAt != (u32)$FFFFFFFF)
                    {
                    String* e = String.withCString("xcc-ln-win64: error: two modules define category '");
                    e.append(nm.substringFromByte(catAt + (u32)5));
                    e.appendCString("' on class '");
                    e.append(nm.substringBytes((u32)0, catAt));
                    e.appendCString("' ('");
                    e.append(nm);
                    e.appendCString("' defined twice). The category name is the extender's identity "
                                    "(separate-compilation §4.3b) — rename one, or compile both from one module\n");
                    Stdio.error(e);
                    fail(String.withCString("duplicate category"));
                    return false;
                    }
                if (nm.hasSuffix(String.withCString("$cat")))
                    {
                    String* e = String.withCString("xcc-ln-win64: error: class '");
                    e.append(nm.substringBytes((u32)0, nm.byteLength() - (u32)4));
                    e.appendCString("' is compiled into two modules ('");
                    e.append(nm);
                    e.appendCString("', its category-chain table, defined twice)\n");
                    Stdio.error(e);
                    fail(String.withCString("class in two modules"));
                    return false;
                    }
                continue;
                }
            if (sd.where() == (u32)1)
                msyms.set((Hashable*)nm, (Object*)Number.withU32(tbase + sd.off()));
            else
                {
                msyms.set((Hashable*)nm, (Object*)Number.withU32(dbase + sd.off()));
                mdataSyms.add((Object*)nm);
                }
            }
        Array* rl = obj.relocs();
        for (u32 k = (u32)0; k < rl.count(); k = k + (u32)1)
            {
            ElfReloc* r = (ElfReloc*)rl.get(k);
            bool secrel = r.type() == (u32)COFF_REL_SECREL;
            if ((r.type() != (u32)COFF_REL_REL32 && !secrel) || r.sym() >= sdefs.count())
                {
                fail(String.withCString("unhandled text relocation in ").appending(whence));
                return false;
                }
            // SECREL: a thread-local's offset in the template (gs:[58h]'s
            // block for this module, indexed by _tls_index).
            mfix.add((Object*)X86Fixup.make(tbase + r.off(), secrel ? (u32)X86FIX_SECREL32 : (u32)X86FIX_REL32,
                                            PeLink.taggedAt((ElfSymDef*)sdefs.get(r.sym()), oi, r.sym()), (i32)r.addend()));
            }
        Array* dl = obj.dataRelocs();
        for (u32 k = (u32)0; k < dl.count(); k = k + (u32)1)
            {
            ElfReloc* r = (ElfReloc*)dl.get(k);
            // A REL32 in data is a slot holding an offset from itself: gcc's
            // switch jump tables in .rdata, as musl's vfprintf has on ELF.
            u32 kind = (u32)X86FIX_ABS64;
            if (r.type() == (u32)COFF_REL_REL32)
                kind = (u32)X86FIX_PC32DATA;
            // An image-relative address (.xdata's personality routine).
            if (r.type() == (u32)COFF_REL_ADDR32NB)
                kind = (u32)X86FIX_RVA32;
            if ((r.type() != (u32)COFF_REL_ADDR64 && r.type() != (u32)COFF_REL_REL32 && r.type() != (u32)COFF_REL_ADDR32NB)
                || r.sym() >= sdefs.count())
                {
                fail(String.withCString("unhandled data relocation in ").appending(whence));
                return false;
                }
            mfix.add((Object*)X86Fixup.make(dbase + r.off(), kind,
                                            PeLink.taggedAt((ElfSymDef*)sdefs.get(r.sym()), oi, r.sym()), (i32)r.addend()));
            }
        // Pointers in the template (rare): absolute, settled once it is placed.
        Array* tl = obj.tlsRelocs();
        for (u32 k = (u32)0; k < tl.count(); k = k + (u32)1)
            {
            ElfReloc* r = (ElfReloc*)tl.get(k);
            if (r.type() != (u32)COFF_REL_ADDR64 || r.sym() >= sdefs.count())
                {
                fail(String.withCString("unhandled .tls relocation in ").appending(whence));
                return false;
                }
            _tlsFix.add((Object*)X86Fixup.make(tlbase + r.off(), (u32)X86FIX_ABS64,
                                               PeLink.taggedAt((ElfSymDef*)sdefs.get(r.sym()), oi, r.sym()), (i32)r.addend()));
            }
        // .ctors: each a constructor's address, joining the one list.
        if (obj.ctors().length() > (u32)0)
            {
            PeLink.padArray(_ctors, (u32)7);
            u32 cbase = _ctors.length();
            PeLink.appendData(_ctors, obj.ctors());
            Array* cl = obj.ctorsRelocs();
            for (u32 k = (u32)0; k < cl.count(); k = k + (u32)1)
                {
                ElfReloc* r = (ElfReloc*)cl.get(k);
                if (r.type() != (u32)COFF_REL_ADDR64 || r.sym() >= sdefs.count())
                    {
                    fail(String.withCString("unhandled .ctors relocation in ").appending(whence));
                    return false;
                    }
                _ctorsFix.add((Object*)X86Fixup.make(cbase + r.off(), (u32)X86FIX_ABS64,
                                                     PeLink.taggedAt((ElfSymDef*)sdefs.get(r.sym()), oi, r.sym()), (i32)r.addend()));
                }
            }
        // .pdata (a C++ program's): its function entries join the one table,
        // each word an image-relative address.
        if (obj.pdata().length() > (u32)0)
            {
            PeLink.padArray(_pdata, (u32)3);
            u32 pbase = _pdata.length();
            PeLink.appendData(_pdata, obj.pdata());
            Array* pl = obj.pdataRelocs();
            for (u32 k = (u32)0; k < pl.count(); k = k + (u32)1)
                {
                ElfReloc* r = (ElfReloc*)pl.get(k);
                if (r.type() != (u32)COFF_REL_ADDR32NB || r.sym() >= sdefs.count())
                    {
                    fail(String.withCString("unhandled .pdata relocation in ").appending(whence));
                    return false;
                    }
                _pdataFix.add((Object*)X86Fixup.make(pbase + r.off(), (u32)X86FIX_RVA32,
                                                     PeLink.taggedAt((ElfSymDef*)sdefs.get(r.sym()), oi, r.sym()), (i32)r.addend()));
                }
            }
        return true;
        }

    // The thread-local template at the end of data (__xc_tls_start ..
    // __xc_tls_end), with what the loader needs to give each thread its
    // copy: _tls_index (unless an object defines it), an empty callback
    // list and the IMAGE_TLS_DIRECTORY64 (__xc_tls_dir) the writer names
    // data directory 9.
    void placeTls(SectionBytes* mdata, Map* msyms, Array* mdataSyms, Array* mfix)
        {
        if (_tls.length() == (u32)0)
            return;
        PeLink.padArray(mdata, (u32)15);
        u32 base = mdata.length();
        PeLink.defineData(msyms, mdataSyms, String.withCString("__xc_tls_start"), base);
        for (u32 i = (u32)0; i < _tls.length(); i = i + (u32)1)
            mdata.appendByte(_tls.byteAt(i));
        PeLink.defineData(msyms, mdataSyms, String.withCString("__xc_tls_end"), mdata.length());
        Array* names = _tlsSyms.allKeys();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* nm = (String*)names.get(i);
            if (msyms.get((Hashable*)nm) == (Object*)0)
                PeLink.defineData(msyms, mdataSyms, nm, base + ((Number*)_tlsSyms.get((Hashable*)nm)).asU32());
            }
        for (u32 k = (u32)0; k < _tlsFix.count(); k = k + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)_tlsFix.get(k);
            mfix.add((Object*)X86Fixup.make(base + f.offset(), f.kind(), f.symbol(), f.addend()));
            }
        PeLink.padArray(mdata, (u32)7);
        String* idx = String.withCString("_tls_index");
        if (msyms.get((Hashable*)idx) == (Object*)0)
            {
            PeLink.defineData(msyms, mdataSyms, idx, mdata.length());
            for (u32 b = (u32)0; b < (u32)8; b = b + (u32)1)
                mdata.appendByte((u8)0);
            }
        PeLink.defineData(msyms, mdataSyms, String.withCString("__xc_tls_callbacks"), mdata.length());
        for (u32 b = (u32)0; b < (u32)8; b = b + (u32)1)
            mdata.appendByte((u8)0);
        u32 dir = mdata.length();
        PeLink.defineData(msyms, mdataSyms, String.withCString("__xc_tls_dir"), dir);
        for (u32 b = (u32)0; b < (u32)40; b = b + (u32)1)
            mdata.appendByte((u8)0);
        mfix.add((Object*)X86Fixup.make(dir, (u32)X86FIX_ABS64, String.withCString("__xc_tls_start"), (i32)0));
        mfix.add((Object*)X86Fixup.make(dir + (u32)8, (u32)X86FIX_ABS64, String.withCString("__xc_tls_end"), (i32)0));
        mfix.add((Object*)X86Fixup.make(dir + (u32)16, (u32)X86FIX_ABS64, idx, (i32)0));
        mfix.add((Object*)X86Fixup.make(dir + (u32)24, (u32)X86FIX_ABS64, String.withCString("__xc_tls_callbacks"), (i32)0));
        }

    // The constructor list (__xc_ctors_start .. __xc_ctors_end) and, when
    // the program calls it (clang's main for mingw does), __main: mingw's
    // libgcc routine that runs it, last entry first (a library's
    // constructors, linked after the program's, run before them).
    void placeCtors(SectionBytes* mtext, SectionBytes* mdata, Map* msyms, Array* mdataSyms, Array* mfix)
        {
        String* mainNm = String.withCString("__main");
        bool wantMain = false;
        for (u32 i = (u32)0; i < mfix.count() && !wantMain; i = i + (u32)1)
            {
            String* s = ((X86Fixup*)mfix.get(i)).symbol();
            if (s != (String*)0 && s.equals(mainNm))
                wantMain = true;
            }
        if (_ctors.length() == (u32)0 && !wantMain)
            {
            self.atexitStub(mtext, msyms, mfix);
            return;
            }
        PeLink.padArray(mdata, (u32)7);
        u32 base = mdata.length();
        PeLink.defineData(msyms, mdataSyms, String.withCString("__xc_ctors_start"), base);
        for (u32 i = (u32)0; i < _ctors.length(); i = i + (u32)1)
            mdata.appendByte(_ctors.byteAt(i));
        PeLink.defineData(msyms, mdataSyms, String.withCString("__xc_ctors_end"), mdata.length());
        for (u32 k = (u32)0; k < _ctorsFix.count(); k = k + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)_ctorsFix.get(k);
            mfix.add((Object*)X86Fixup.make(base + f.offset(), f.kind(), f.symbol(), f.addend()));
            }
        self.atexitStub(mtext, msyms, mfix);
        if (!wantMain || msyms.get((Hashable*)mainNm) != (Object*)0)
            return;
        // __main: push rbx; push rsi; sub rsp,40; lea rbx,[end]; lea rsi,[start]
        // loop: cmp rbx,rsi; jbe done; sub rbx,8; call [rbx]; jmp loop
        // done: add rsp,40; pop rsi; pop rbx; ret
        PeLink.padArray(mtext, (u32)15);
        msyms.set((Hashable*)mainNm, (Object*)Number.withU32(mtext.length()));
        PeLink.hex(mtext, "53 56 48 83 EC 28 48 8D 1D");
        mfix.add((Object*)X86Fixup.make(mtext.length(), (u32)X86FIX_REL32, String.withCString("__xc_ctors_end"), (i32)-4));
        PeLink.hex(mtext, "00 00 00 00 48 8D 35");
        mfix.add((Object*)X86Fixup.make(mtext.length(), (u32)X86FIX_REL32, String.withCString("__xc_ctors_start"), (i32)-4));
        PeLink.hex(mtext, "00 00 00 00");
        // loop: cmp rbx,rsi; jbe done (+8); sub rbx,8; call [rbx]; jmp loop (-13)
        PeLink.hex(mtext, "48 39 F3 76 08 48 83 EB 08 FF 13 EB F3");
        // done: add rsp,40; pop rsi; pop rbx; ret
        PeLink.hex(mtext, "48 83 C4 28 5E 5B C3");
        }

    void atexitStub(SectionBytes* mtext, Map* msyms, Array* mfix)
        {
        // atexit, which mingw's crt2.o defines over ucrt's _crt_atexit (the
        // same signature): a jump to that import. (xcc's start-up ends in
        // ExitProcess, so what it registers - static destructors - does not
        // run at exit yet.)
        String* ax = String.withCString("atexit");
        bool wantAtexit = false;
        for (u32 i = (u32)0; i < mfix.count() && !wantAtexit; i = i + (u32)1)
            {
            String* s = ((X86Fixup*)mfix.get(i)).symbol();
            if (s != (String*)0 && s.equals(ax))
                wantAtexit = true;
            }
        if (wantAtexit && msyms.get((Hashable*)ax) == (Object*)0)
            {
            PeLink.padArray(mtext, (u32)15);
            msyms.set((Hashable*)ax, (Object*)Number.withU32(mtext.length()));
            PeLink.hex(mtext, "E9");
            mfix.add((Object*)X86Fixup.make(mtext.length(), (u32)X86FIX_REL32, String.withCString("_crt_atexit"), (i32)-4));
            PeLink.hex(mtext, "00 00 00 00");
            }
        }

    static void hex2(SectionBytes* t, string s)
        {
        PeLink.hex(t, s);
        }

    // Bytes written as hex pairs separated by spaces.
    static void hex(SectionBytes* t, string s)
        {
        String* w = String.withCString(s);
        u32 v = (u32)0;
        u32 n = (u32)0;
        for (u32 i = (u32)0; i <= w.byteLength(); i = i + (u32)1)
            {
            u8 c = i < w.byteLength() ? w.byteAt(i) : (u8)' ';
            if (c == (u8)' ')
                {
                if (n > (u32)0)
                    t.appendByte((u8)v);
                v = (u32)0;
                n = (u32)0;
                continue;
                }
            u32 d = c >= (u8)'A' ? (u32)c - (u32)'A' + (u32)10 : (u32)c - (u32)'0';
            v = v * (u32)16 + d;
            n = n + (u32)1;
            }
        }

    static void defineData(Map* msyms, Array* mdataSyms, String* nm, u32 off)
        {
        msyms.set((Hashable*)nm, (Object*)Number.withU32(off));
        mdataSyms.add((Object*)nm);
        }

    // The .pdata table at the end of data, between __xc_pdata_start and
    // __xc_pdata_end: the writer sorts it and names it the exception
    // directory.
    void placePdata(SectionBytes* mdata, Map* msyms, Array* mdataSyms, Array* mfix)
        {
        if (_pdata.length() == (u32)0)
            return;
        // xcc's _start (crt-win64.s) gets an entry too: the unwinder reads the
        // frame that called each handler's, and main's is _start's. Its
        // prologue is `sub rsp, 40`: one UWOP_ALLOC_SMALL of 40. It ends where
        // the next function in text begins.
        Object* st = msyms.get((Hashable*)String.withCString("_start"));
        if (st != (Object*)0)
            {
            u32 s0 = ((Number*)st).asU32();
            Set* dataSet = Set.withArray(mdataSyms);
            u32 s1 = (u32)$FFFFFFFF;
            Array* keys = msyms.allKeys();
            for (u32 i = (u32)0; i < keys.count(); i = i + (u32)1)
                {
                String* k = (String*)keys.get(i);
                // A local label (.Lctors) is inside _start, not after it.
                if (dataSet.contains((Hashable*)k) || k.hasPrefix(String.withCString(".")))
                    continue;
                u32 o = ((Number*)msyms.get((Hashable*)k)).asU32();
                if (o > s0 && o < s1)
                    s1 = o;
                }
            if (s1 != (u32)$FFFFFFFF)
                {
                PeLink.padArray(mdata, (u32)3);
                PeLink.defineData(msyms, mdataSyms, String.withCString("__xc_start_unwind"), mdata.length());
                PeLink.hex2(mdata, "01 04 01 00 04 42 00 00");
                PeLink.padArray(_pdata, (u32)3);
                u32 pe = _pdata.length();
                for (u32 b = (u32)0; b < (u32)12; b = b + (u32)1)
                    _pdata.appendByte((u8)0);
                _pdataFix.add((Object*)X86Fixup.make(pe, (u32)X86FIX_RVA32, String.withCString("_start"), (i32)0));
                _pdataFix.add((Object*)X86Fixup.make(pe + (u32)4, (u32)X86FIX_RVA32, String.withCString("_start"), (i32)(s1 - s0)));
                _pdataFix.add((Object*)X86Fixup.make(pe + (u32)8, (u32)X86FIX_RVA32, String.withCString("__xc_start_unwind"), (i32)0));
                }
            }
        PeLink.padArray(mdata, (u32)3);
        u32 base = mdata.length();
        msyms.set((Hashable*)String.withCString("__xc_pdata_start"), (Object*)Number.withU32(base));
        mdataSyms.add((Object*)String.withCString("__xc_pdata_start"));
        for (u32 i = (u32)0; i < _pdata.length(); i = i + (u32)1)
            mdata.appendByte(_pdata.byteAt(i));
        msyms.set((Hashable*)String.withCString("__xc_pdata_end"), (Object*)Number.withU32(mdata.length()));
        mdataSyms.add((Object*)String.withCString("__xc_pdata_end"));
        for (u32 k = (u32)0; k < _pdataFix.count(); k = k + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)_pdataFix.get(k);
            mfix.add((Object*)X86Fixup.make(base + f.offset(), f.kind(), f.symbol(), f.addend()));
            }
        }

    // Explicit objects in order, then archive members to a fixpoint: each
    // round recomputes what the image lacks and walks the pool in archive
    // order taking every untaken member that defines one of them — the
    // reference's loop, and 133's rule.
    void merge(Array* objectFiles, Array* archives,
               SectionBytes* mtext, SectionBytes* mdata, Map* msyms, Array* mdataSyms, Array* mfix)
        {
        for (u32 oi = (u32)0; oi < objectFiles.count(); oi = oi + (u32)1)
            {
            String* op = (String*)objectFiles.get(oi);
            Data* d = Files.readData(op);
            CoffObject* o = d == (Data*)0 ? (CoffObject*)0 : CoffObject.parse(d);
            if (o == (CoffObject*)0 || !o.ok())
                {
                fail(String.withCString("'").appending(op).appending(String.withCString("' is not a readable x86-64 COFF object")));
                return;
                }
            if (!mergeOne(o, op, oi, mtext, mdata, msyms, mdataSyms, mfix))
                return;
            }
        if (archives.count() == (u32)0)
            {
            self.placeTls(mdata, msyms, mdataSyms, mfix);
            self.placeCtors(mtext, mdata, msyms, mdataSyms, mfix);
            self.placePdata(mdata, msyms, mdataSyms, mfix);
            return;
            }
        Array* pool = new Array();
        Array* poolFrom = new Array();
        for (u32 a = (u32)0; a < archives.count(); a = a + (u32)1)
            {
            String* ap = (String*)archives.get(a);
            Array* ms = ArArchive.membersOfFile(ap);
            if (ms == (Array*)0)
                {
                fail(String.withCString("'").appending(ap).appending(String.withCString("' is not a static archive")));
                return;
                }
            for (u32 k = (u32)0; k < ms.count(); k = k + (u32)1)
                {
                ArMember* m = (ArMember*)ms.get(k);
                CoffObject* o = CoffObject.parse(m.data());
                if (!o.ok())
                    continue;
                pool.add((Object*)o);
                String* label = String.withString(ap.lastPathComponent());
                label.appendCString("(");
                label.append(m.name());
                label.appendCString(")");
                poolFrom.add((Object*)label);
                }
            }
        Map* taken = new Map();
        bool progress = true;
        while (progress)
            {
            progress = false;
            Map* needed = new Map();
            for (u32 i = (u32)0; i < mfix.count(); i = i + (u32)1)
                {
                X86Fixup* f = (X86Fixup*)mfix.get(i);
                if (f.symbol() == (String*)0 || f.symbol().byteLength() == (u32)0)
                    continue;
                if (msyms.get((Hashable*)f.symbol()) != (Object*)0 || _tlsSyms.get((Hashable*)f.symbol()) != (Object*)0)
                    continue;
                needed.set((Hashable*)f.symbol(), (Object*)Number.withU32((u32)1));
                }
            if (needed.count() == (u32)0)
                break;
            for (u32 mi = (u32)0; mi < pool.count(); mi = mi + (u32)1)
                {
                Number* key = Number.withU32(mi);
                if (taken.get((Hashable*)key) != (Object*)0)
                    continue;
                CoffObject* obj = (CoffObject*)pool.get(mi);
                Array* sdefs = obj.symdefs();
                bool defines = false;
                for (u32 si = (u32)0; si < sdefs.count() && !defines; si = si + (u32)1)
                    {
                    ElfSymDef* sd = (ElfSymDef*)sdefs.get(si);
                    if (sd.where() != (u32)0 && sd.ext() && needed.get((Hashable*)sd.name()) != (Object*)0)
                        defines = true;
                    }
                if (!defines)
                    continue;
                taken.set((Hashable*)key, (Object*)Number.withU32((u32)1));
                progress = true;
                if (!mergeOne(obj, (String*)poolFrom.get(mi), (u32)1000 + mi, mtext, mdata, msyms, mdataSyms, mfix))
                    return;
                }
            }
        self.placeTls(mdata, msyms, mdataSyms, mfix);
        self.placeCtors(mtext, mdata, msyms, mdataSyms, mfix);
        self.placePdata(mdata, msyms, mdataSyms, mfix);
        }

    static u32 indexOf(String* s, String* needle)
        {
        u32 n = needle.byteLength();
        if (n == (u32)0 || s.byteLength() < n)
            return (u32)$FFFFFFFF;
        for (u32 i = (u32)0; i + n <= s.byteLength(); i = i + (u32)1)
            {
            bool m = true;
            for (u32 k = (u32)0; k < n && m; k = k + (u32)1)
                if (s.byteAt(i + k) != needle.byteAt(k))
                    m = false;
            if (m)
                return i;
            }
        return (u32)$FFFFFFFF;
        }
    }
