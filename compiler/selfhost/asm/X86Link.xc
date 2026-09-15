// X86Link.xc — assemble x86-64 sources and link them, archives included.
// =================================================================
//
// The link that `xtldx86` performs and that the driver performs for
// `-A x86_64` are the same link, so it lives in ONE place. Duplicating it
// would guarantee the two drift, and a linker that behaves differently
// depending on which binary invoked it is the worst kind of difference to
// track down.
//
// Sources come in as ALREADY-SEPARATE strings, not concatenated: each one's
// local labels are namespaced before joining, because two clang-generated
// files both use `.LBB0_1` and without this every branch in the first would
// land in the second.
#import "Foundation.xc"
#import "Files.xc"
#import "X86Asm.xc"
#import "Elf64.xc"
#import "ArResolve.xc"
#import "ElfMerge.xc"

class X86Link
    {
    bool _failed;
    String* _why;

    void init(void)
        {
        _failed = false;
        _why = new String();
        }
    bool failed(void)
        {
        return _failed;
        }
    String* why(void)
        {
        return _why;
        }
    void fail(String* w)
        {
        if (!_failed)
            {
            _failed = true;
            _why = w;
            }
        }

    // `.L<rest>` becomes `.L<index>Z<rest>` — what the reference linker does,
    // and what lets two separately compiled files be joined at all.
    static String* namespaceLocals(String* s, u32 idx)
        {
        String* out = new String();
        u32 i = (u32)0;
        while (i < s.byteLength())
            {
            if (i + (u32)1 < s.byteLength() && s.byteAt(i) == (u8)'.' && s.byteAt(i + (u32)1) == (u8)'L')
                {
                out.appendCString(".L");
                out.appendFormat("%luZ", idx);
                i = i + (u32)2;
                continue;
                }
            out.appendByte(s.byteAt(i));
            i = i + (u32)1;
            }
        return out;
        }

    // X86Asm carries bytes as an Array of boxed Numbers, ElfObject/ElfMerge
    // carry Data. The two meet HERE and nowhere else.
    static Data* bytesToData(Array* a)
        {
        Data* d = Data.withCapacity(a.count());
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            d.appendByte((u8)((Number*)a.get(i)).asU32());
        return d;
        }

    static Array* dataToBytes(Data* d)
        {
        Array* a = new Array();
        for (u32 i = (u32)0; i < d.length(); i = i + (u32)1)
            a.add((Object*)Number.withU32((u32)d.byteAt(i)));
        return a;
        }

    // srcs: assembly texts, in order. objs/ars: paths.
    // A SHARED OBJECT rather than an executable: the same assembly, laid out
    // as ET_DYN with a soname, an export list and the module interface. Kept
    // beside link() rather than folded into it because the two disagree about
    // almost everything after the assembler — segment layout, symbol tables,
    // relocation kinds — and a flag threaded through all of that is how one of
    // them ends up quietly emitting the other's shape.
    // `exports` may be null, in which case the library publishes what the
    // ASSEMBLER saw declared `.globl` — which is what the reference does, and
    // what makes "public" a property of the code rather than of the caller.
    Data* linkShared(Array* srcs, Array* objs, Array* ars, String* soname,
                     Array* exports, Array* needed, String* runpath, Array* iface)
        {
        String* src = new String();
        for (u32 k = (u32)0; k < srcs.count(); k = k + (u32)1)
            {
            String* one = (String*)srcs.get(k);
            if (srcs.count() > (u32)1)
                one = X86Link.namespaceLocals(one, k);
            src.append(one);
            src.appendCString("\n");
            }
        X86Asm* a = new X86Asm();
        a.assemble(src);
        if (a.failed())
            {
            fail(String.withCString("assembly failed: ").appending(a.why()));
            return (Data*)0;
            }
        // This unit's own COMMON tentative globals get real storage — an image
        // has no separate stage to allocate them (bug 36 cross-object). Foreign
        // `.o` commons are resolved by the merge below.
        a.demoteCommonsToLocalData();
        Array* pub = exports != (Array*)0 ? exports : a.globalSyms();
        Elf64* e = new Elf64();
        if (objs.count() == (u32)0 && ars.count() == (u32)0)
            {
            e.sharedObject(X86Link.bytesToData(a.text()), X86Link.bytesToData(a.data()),
                           a.symbols(), a.dataSyms(),
                           pub, a.fixups(), soname, needed,
                           (String*)0, runpath, iface, new Array(),
                           new Data(), new Array(), (u32)1);
            }
        else
            {
            MergedImage* im = seedFrom(a);
            for (u32 k = (u32)0; k < objs.count(); k = k + (u32)1)
                {
                String* op = (String*)objs.get(k);
                Data* od = Files.readData(op);
                if (od == (Data*)0)
                    {
                    fail(String.withCString("cannot read ").appending(op));
                    return (Data*)0;
                    }
                ElfObject* oo = ElfObject.parse(od);
                if (!oo.ok())
                    {
                    fail(op.appending(String.withCString(" is not a readable x86-64 object")));
                    return (Data*)0;
                    }
                ElfMerge.merge(im, oo, op, k);
                if (im.failed())
                    {
                    fail(im.why());
                    return (Data*)0;
                    }
                }
            if (ars.count() > (u32)0)
                {
                pullFromArchives(im, ars, (Array*)0);
                if (im.failed())
                    {
                    fail(im.why());
                    return (Data*)0;
                    }
                }
            if (!applyStaticTls(im))
                return (Data*)0;
            e.sharedObject(im.text(),
                           im.data(),
                           im.syms(), im.dataSyms(), pub, im.fixups(),
                           soname, needed, (String*)0, runpath, iface, new Array(),
                           im.bss(), im.bssSyms(), im.bssAlign());
            }
        if (e.failed())
            {
            fail(e.why());
            return (Data*)0;
            }
        return e.bytes();
        }

    // A DYNAMICALLY-LINKED executable: the same ET_DYN image as a shared object
    // plus PT_PHDR, PT_INTERP and an entry point, with a DT_NEEDED per library.
    // ld.so processes the same PT_DYNAMIC either way, which is why one writer
    // covers both.
    //
    // This is what lets `#import <Lib>` reach a `.so` at run time: a STATIC
    // executable has no interpreter and no DT_NEEDED, so the library it named
    // is simply not there when it runs.
    // `alsoExport` are names the LIBRARIES need from us. A `.so` this program
    // loads imports its libc from the program — one libc in the image, and the
    // executable is the provider — so anything it left undefined that we
    // define has to appear in OUR dynamic symbol table or ld.so cannot bind
    // it. Without this the library loaded and died on `undefined symbol:
    // calloc`, which the app had all along, privately.
    Data* linkDynamic(Array* srcs, Array* objs, Array* ars, String* entry,
                      Array* needed, String* runpath, Array* alsoExport)
        {
        String* src = new String();
        for (u32 k = (u32)0; k < srcs.count(); k = k + (u32)1)
            {
            String* one = (String*)srcs.get(k);
            if (srcs.count() > (u32)1)
                one = X86Link.namespaceLocals(one, k);
            src.append(one);
            src.appendCString("\n");
            }
        X86Asm* a = new X86Asm();
        a.assemble(src);
        if (a.failed())
            {
            fail(String.withCString("assembly failed: ").appending(a.why()));
            return (Data*)0;
            }
        // This unit's own COMMON tentative globals get real storage — an image
        // has no separate stage to allocate them (bug 36 cross-object). Foreign
        // `.o` commons are resolved by the merge below.
        a.demoteCommonsToLocalData();
        Array* pub = new Array();
        for (u32 k = (u32)0; k < a.globalSyms().count(); k = k + (u32)1)
            pub.add(a.globalSyms().get(k));
        for (u32 k = (u32)0; alsoExport != (Array*)0 && k < alsoExport.count();
             k = k + (u32)1)
            pub.add(alsoExport.get(k));
        Elf64* e = new Elf64();
        if (objs.count() == (u32)0 && ars.count() == (u32)0)
            {
            e.sharedObject(X86Link.bytesToData(a.text()), X86Link.bytesToData(a.data()),
                           a.symbols(), a.dataSyms(),
                           pub, a.fixups(), (String*)0, needed,
                           entry, runpath, new Array(), new Array(),
                           new Data(), new Array(), (u32)1);
            }
        else
            {
            MergedImage* im = seedFrom(a);
            for (u32 k = (u32)0; k < objs.count(); k = k + (u32)1)
                {
                String* op = (String*)objs.get(k);
                Data* od = Files.readData(op);
                if (od == (Data*)0)
                    {
                    fail(String.withCString("cannot read ").appending(op));
                    return (Data*)0;
                    }
                ElfObject* oo = ElfObject.parse(od);
                if (!oo.ok())
                    {
                    fail(op.appending(String.withCString(" is not a readable x86-64 object")));
                    return (Data*)0;
                    }
                ElfMerge.merge(im, oo, op, k);
                if (im.failed())
                    {
                    fail(im.why());
                    return (Data*)0;
                    }
                }
            if (ars.count() > (u32)0)
                {
                // (the pull itself is shared with the static path: pullFromArchives)
                pullFromArchives(im, ars, alsoExport);
                if (im.failed())
                    {
                    fail(im.why());
                    return (Data*)0;
                    }
                }
            if (!applyStaticTls(im))
                return (Data*)0;
            // The init/fini array bounds and the weak-undef zeroes, exactly as
            // the static path synthesises them: musl's start/exit code walks
            // those arrays, and a dynamic image needs them just as much.
            Array* absSyms = synthesizeLinkerSymbols(im);
            e.sharedObject(im.text(),
                           im.data(),
                           im.syms(), im.dataSyms(), pub, im.fixups(),
                           (String*)0, needed, entry, runpath, new Array(), absSyms,
                           im.bss(), im.bssSyms(), im.bssAlign());
            }
        if (e.failed())
            {
            fail(e.why());
            return (Data*)0;
            }
        return e.bytes();
        }

    Data* link(Array* srcs, Array* objs, Array* ars, String* entry)
        {
        String* src = new String();
        for (u32 k = (u32)0; k < srcs.count(); k = k + (u32)1)
            {
            String* one = (String*)srcs.get(k);
            if (srcs.count() > (u32)1)
                one = X86Link.namespaceLocals(one, k);
            src.append(one);
            src.appendCString("\n");
            }
        X86Asm* a = new X86Asm();
        a.assemble(src);
        if (a.failed())
            {
            fail(String.withCString("assembly failed: ").appending(a.why()));
            return (Data*)0;
            }
        // This unit's own COMMON tentative globals get real storage — an image
        // has no separate stage to allocate them (bug 36 cross-object). Foreign
        // `.o` commons are resolved by the merge below.
        a.demoteCommonsToLocalData();

        Elf64* e = new Elf64();
        if (objs.count() == (u32)0 && ars.count() == (u32)0)
            {
            // No foreign input: the original path, byte for byte.
            e.staticExecutable(a.text(), a.data(), a.symbols(), a.dataSyms(),
                               a.fixups(), entry);
            }
        else
            {
            MergedImage* im = seedFrom(a);
            u32 seedTextEnd = im.text().length(); // seed/runtime kept wholesale by the GC
            u32 seedDataEnd = im.data().length();
            for (u32 k = (u32)0; k < objs.count(); k = k + (u32)1)
                {
                String* op = (String*)objs.get(k);
                Data* od = Files.readData(op);
                if (od == (Data*)0)
                    {
                    fail(String.withCString("cannot read ").appending(op));
                    return (Data*)0;
                    }
                ElfObject* oo = ElfObject.parse(od);
                if (!oo.ok())
                    {
                    fail(op.appending(String.withCString(" is not a readable x86-64 object")));
                    return (Data*)0;
                    }
                ElfMerge.merge(im, oo, op, k);
                if (im.failed())
                    {
                    fail(im.why());
                    return (Data*)0;
                    }
                }
            if (ars.count() > (u32)0)
                {
                pullFromArchives(im, ars, (Array*)0);
                if (im.failed())
                    {
                    fail(im.why());
                    return (Data*)0;
                    }
                }
            if (!applyStaticTls(im))
                return (Data*)0;
            Array* absSyms = synthesizeLinkerSymbols(im);
            im.gcDead(seedTextEnd, seedDataEnd, entry); // bug 196: drop dead code and data
            e.staticExecutableAbs(im.text(),
                                  im.data(),
                                  im.syms(), im.dataSyms(), absSyms,
                                  im.fixups(), entry,
                                  im.bss(), im.bssSyms(), im.bssAlign());
            }
        if (e.failed())
            {
            fail(e.why());
            return (Data*)0;
            }

        return e.bytes();
        }

    // The archive fixpoint, EXACTLY as xtcln-x86_64 runs it (bug 133): each
    // round recomputes what the IMAGE still lacks — every fixup naming a
    // symbol nothing merged so far defines, weak or not, plus what the shared
    // deps import — and then walks the whole pool in archive order, taking
    // every untaken member that defines one of them. A member's own
    // undefineds are not chased by themselves: they are simply undefined in
    // the image next round, which is where the crt's `__environ` and `__libc`
    // already answer them. The first port chased them in a private want-list
    // that never saw the image, so musl's __environ.lo and libc.lo were
    // pulled to define what crt-linux.s had defined all along — 256 bytes of
    // duplicate data the reference never linked. Members are namespaced by
    // their POOL index (1000 + mi), as the reference does, not by pick order.
    static String* lastComponent(String* path)
        {
        u32 cut = (u32)0;
        for (u32 i = (u32)0; i < path.byteLength(); i = i + (u32)1)
            if (path.byteAt(i) == (u8)'/')
                cut = i + (u32)1;
        if (cut == (u32)0)
            return path;
        return path.substringBytes(cut, path.byteLength() - cut);
        }

    void pullFromArchives(MergedImage* im, Array* ars, Array* alsoWant)
        {
        ArResolve* r = new ArResolve();
        for (u32 k = (u32)0; k < ars.count(); k = k + (u32)1)
            r.addArchive((String*)ars.get(k));
        Array* pool = r.members();
        Map* taken = new Map();
        bool progress = true;
        while (progress)
            {
            progress = false;
            Map* needed = new Map();
            Array* want = stillUndefined(im);
            for (u32 q = (u32)0; q < want.count(); q = q + (u32)1)
                needed.set((Hashable*)want.get(q), (Object*)Number.withU32((u32)1));
            for (u32 q = (u32)0; alsoWant != (Array*)0 && q < alsoWant.count(); q = q + (u32)1)
                {
                String* u = (String*)alsoWant.get(q);
                if (im.syms().get((Hashable*)u) != (Object*)0)
                    continue;
                needed.set((Hashable*)u, (Object*)Number.withU32((u32)1));
                }
            if (needed.count() == (u32)0)
                break;
            for (u32 mi = (u32)0; mi < pool.count(); mi = mi + (u32)1)
                {
                Number* key = Number.withU32(mi);
                if (taken.get((Hashable*)key) != (Object*)0)
                    continue;
                ArPick* pk = (ArPick*)pool.get(mi);
                Array* def = pk.object().definedNames();
                bool defines = false;
                for (u32 k = (u32)0; k < def.count() && !defines; k = k + (u32)1)
                    if (needed.get((Hashable*)def.get(k)) != (Object*)0)
                        defines = true;
                if (!defines)
                    continue;
                taken.set((Hashable*)key, (Object*)Number.withU32((u32)1));
                progress = true;
                String* label = String.withString(X86Link.lastComponent(pk.archive()));
                label.appendCString("(");
                label.append(pk.member().name());
                label.appendCString(")");
                ElfMerge.merge(im, pk.object(), label, (u32)1000 + mi);
                if (im.failed())
                    return;
                }
            }
        }

    // ── static local-exec TLS (bug 139: the port had none) ───────────────
    // The per-thread block sits at [%fs - R, %fs): variant II, R = the TLS
    // image size rounded to 16. The image itself is stored in the crt's
    // __xt_tls_hdr data area ([0]=R, [8..8+R) = bytes) — the startup and
    // _xt_tcb_alloc copy it below every tcb, whose 248 reserved bytes cap R
    // at 240 (a hard error, not a silent overrun). Each TPOFF32 becomes the
    // CONSTANT tlsOff - R carried in the fixup's addend; the writer stores it
    // with no symbol lookup. Exactly xtcln-x86_64's rule — a foreign
    // `__thread` object linked and RAN WRONG (fs:[0]) before this existed.
    bool applyStaticTls(MergedImage* im)
        {
        Array* fix = im.fixups();
        if (im.tls().length() == (u32)0)
            {
            for (u32 i = (u32)0; i < fix.count(); i = i + (u32)1)
                {
                X86Fixup* f = (X86Fixup*)fix.get(i);
                if (f.kind() == (u32)X86FIX_TPOFF32)
                    {
                    fail(String.withCString("TPOFF32 for '").appending(f.symbol()).appending(String.withCString("' with no TLS sections in the link")));
                    return false;
                    }
                }
            return true;
            }
        u32 R = (im.tls().length() + (u32)15) & ~(u32)15;
        if (R > (u32)240)
            {
            fail(String.withCString("static TLS needs more than the 240 bytes the runtime reserves below each thread block"));
            return false;
            }
        String* hn = String.withCString("__xt_tls_hdr");
        Object* hdr = im.syms().get((Hashable*)hn);
        bool inData = false;
        for (u32 i = (u32)0; i < im.dataSyms().count(); i = i + (u32)1)
            if (((String*)im.dataSyms().get(i)).equals(hn))
                inData = true;
        if (hdr == (Object*)0 || !inData)
            {
            fail(String.withCString("TLS inputs need the crt's __xt_tls_hdr (is the runtime missing?)"));
            return false;
            }
        u32 ho = ((Number*)hdr).asU32();
        if (ho + (u32)8 + (u32)240 > im.data().length())
            {
            fail(String.withCString("__xt_tls_hdr area truncated"));
            return false;
            }
        // R as a little-endian u64: the low four bytes carry it (a u32 shift
        // by 32 is not a zero — it wraps — so the high half is written as 0).
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            im.data().setByteAt(ho + i, i < (u32)4 ? (u8)((R >> (i * (u32)8)) & (u32)$FF) : (u8)0);
        for (u32 i = (u32)0; i < im.tls().length(); i = i + (u32)1)
            im.data().setByteAt(ho + (u32)8 + i, im.tls().byteAt(i));
        for (u32 i = (u32)0; i < fix.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)fix.get(i);
            if (f.kind() != (u32)X86FIX_TPOFF32)
                continue;
            Object* lo = im.tlsSyms().get((Hashable*)f.symbol());
            if (lo == (Object*)0)
                {
                fail(String.withCString("undefined TLS symbol '").appending(f.symbol()).appending(String.withCString("'")));
                return false;
                }
            i32 a = (i32)((Number*)lo).asU32() - (i32)R + f.addend();
            fix.set(i, (Object*)X86Fixup.make(f.offset(), (u32)X86FIX_TPOFF32, String.withCString(""), a));
            }
        for (u32 i = (u32)0; i < im.tlsAbs().count(); i = i + (u32)1)
            {
            TlsAbsReloc* r = (TlsAbsReloc*)im.tlsAbs().get(i);
            fix.add((Object*)X86Fixup.make(ho + (u32)8 + r.off(), (u32)X86FIX_ABS64, r.sym(), (i32)r.addend()));
            }
        return true;
        }

    // The image starts as what WE assembled; foreign objects merge on top, so
    // their offsets are relative to the end of ours.
    MergedImage* seedFrom(X86Asm* a)
        {
        MergedImage* im = new MergedImage();
        im.text().append(X86Link.bytesToData(a.text()));
        im.data().append(X86Link.bytesToData(a.data()));
        Array* keys = a.symbols().allKeys();
        for (u32 i = (u32)0; i < keys.count(); i = i + (u32)1)
            {
            String* k = (String*)keys.get(i);
            im.syms().set((Hashable*)k, a.symbols().get((Hashable*)k));
            }
        for (u32 i = (u32)0; i < a.dataSyms().count(); i = i + (u32)1)
            im.dataSyms().add(a.dataSyms().get(i));
        for (u32 i = (u32)0; i < a.fixups().count(); i = i + (u32)1)
            im.fixups().add(a.fixups().get(i));
        return im;
        }

    // Everything the image still refers to and does not define.
    Array* stillUndefined(MergedImage* im)
        {
        Array* out = new Array();
        Map* seen = new Map();
        for (u32 i = (u32)0; i < im.fixups().count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)im.fixups().get(i);
            if (f.symbol() == 0 || f.symbol().byteLength() == (u32)0)
                continue;
            if (im.syms().get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            if (seen.get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            seen.set((Hashable*)f.symbol(), (Object*)Number.withU32((u32)1));
            out.add((Object*)f.symbol());
            }
        return out;
        }

    // The symbols a LINKER provides rather than any object. Called AFTER the
    // archive fixpoint and not before: "nothing defines it" only becomes a
    // fact once the pull has finished.
    Array* synthesizeLinkerSymbols(MergedImage* im)
        {
        Array* abs = new Array();
        // The init/fini array bounds, all equal — so musl's start/exit code
        // walks an EMPTY array. No member of any archive we link carries an
        // .init_array/.fini_array section, so equal bounds is the truthful
        // answer and not a stub standing in for one.
        Array* bounds = new Array();
        bounds.add((Object*)String.withCString("__preinit_array_start"));
        bounds.add((Object*)String.withCString("__preinit_array_end"));
        bounds.add((Object*)String.withCString("__init_array_start"));
        bounds.add((Object*)String.withCString("__init_array_end"));
        bounds.add((Object*)String.withCString("__fini_array_start"));
        bounds.add((Object*)String.withCString("__fini_array_end"));
        // ALL six appear once ANY is wanted — the reference's rule, and the
        // one that makes the two linkers' symbol tables agree (133).
        Array* want = stillUndefined(im);
        bool asked = false;
        for (u32 i = (u32)0; i < bounds.count() && !asked; i = i + (u32)1)
            for (u32 k = (u32)0; k < want.count() && !asked; k = k + (u32)1)
                if (((String*)want.get(k)).equals((String*)bounds.get(i)))
                    asked = true;
        // Text offset 0 — an ADDRESS (the image's text base), not an absolute
        // zero: the reference resolves a fixup naming a bound to 0x4000f0, and
        // treating them as abs here left a data word 0 where it stores that
        // address (the last 8 bytes of 133). Only the weak-undefs are abs.
        for (u32 i = (u32)0; asked && i < bounds.count(); i = i + (u32)1)
            {
            String* b = (String*)bounds.get(i);
            if (im.syms().get((Hashable*)b) != (Object*)0)
                continue;
            im.syms().set((Hashable*)b, (Object*)Number.withU32((u32)0));
            }
        // A WEAK undefined that survived the fixpoint resolves to ABSOLUTE
        // zero — what `if (&_DYNAMIC)`-style probes are written against.
        for (u32 i = (u32)0; i < im.weakUndef().count(); i = i + (u32)1)
            {
            String* w = (String*)im.weakUndef().get(i);
            if (im.syms().get((Hashable*)w) != (Object*)0)
                continue;
            im.syms().set((Hashable*)w, (Object*)Number.withU32((u32)0));
            abs.add((Object*)w);
            }
        return abs;
        }
    }
