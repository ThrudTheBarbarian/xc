// PeLink.xc — merge COFF objects and pull archive members into the x86-64
// assembler's own model for a win64 link. The mirror of xtcln-win64's
// mergeCoffObject and its archive fixpoint (bug 141: the shipped driver's
// win64 link took no objects, no archives and had no C-runtime pool, so a
// program needing `snprintf` could not link and one that did not still
// came out different from the reference).

#import "Foundation.xc"
#import "X86Asm.xc"
#import "CoffObject.xc"
#import "ArArchive.xc"

class PeLink
    {
    String* _why;
    u32 _rc;

    void init(void)
        {
        _rc = (u32)0;
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

    static void padArray(Array* a, u32 mask)
        {
        while ((a.count() & mask) != (u32)0)
            a.add((Object*)Number.withU32((u32)0));
        }
    static void appendData(Array* a, Data* d)
        {
        for (u32 i = (u32)0; i < d.length(); i = i + (u32)1)
            a.add((Object*)Number.withU32((u32)d.byteAt(i)));
        }

    // One object into the image. Text 16-aligned, data 8-aligned; first
    // definition wins except for the category-chain tables (§4.3b), where a
    // duplicate is a wrong CALL and is refused.
    bool mergeOne(CoffObject* obj, String* whence, u32 oi,
                  Array* mtext, Array* mdata, Map* msyms, Array* mdataSyms, Array* mfix)
        {
        PeLink.padArray(mtext, (u32)15);
        u32 tbase = mtext.count();
        PeLink.appendData(mtext, obj.text());
        u32 dbase = mdata.count();
        if (obj.data().length() > (u32)0)
            {
            PeLink.padArray(mdata, (u32)7);
            dbase = mdata.count();
            PeLink.appendData(mdata, obj.data());
            }
        Array* sdefs = obj.symdefs();
        for (u32 si = (u32)0; si < sdefs.count(); si = si + (u32)1)
            {
            ElfSymDef* sd = (ElfSymDef*)sdefs.get(si);
            if (sd.where() == (u32)0 || sd.name().byteLength() == (u32)0)
                continue;
            String* nm = PeLink.tagged(sd, oi);
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
            if (r.type() != (u32)COFF_REL_REL32 || r.sym() >= sdefs.count())
                {
                fail(String.withCString("unhandled text relocation in ").appending(whence));
                return false;
                }
            mfix.add((Object*)X86Fixup.make(tbase + r.off(), (u32)X86FIX_REL32,
                                            PeLink.tagged((ElfSymDef*)sdefs.get(r.sym()), oi), (i32)r.addend()));
            }
        Array* dl = obj.dataRelocs();
        for (u32 k = (u32)0; k < dl.count(); k = k + (u32)1)
            {
            ElfReloc* r = (ElfReloc*)dl.get(k);
            if (r.type() != (u32)COFF_REL_ADDR64 || r.sym() >= sdefs.count())
                {
                fail(String.withCString("unhandled data relocation in ").appending(whence));
                return false;
                }
            mfix.add((Object*)X86Fixup.make(dbase + r.off(), (u32)X86FIX_ABS64,
                                            PeLink.tagged((ElfSymDef*)sdefs.get(r.sym()), oi), (i32)r.addend()));
            }
        return true;
        }

    // Explicit objects in order, then archive members to a fixpoint: each
    // round recomputes what the image lacks and walks the pool in archive
    // order taking every untaken member that defines one of them — the
    // reference's loop, and 133's rule.
    void merge(Array* objectFiles, Array* archives,
               Array* mtext, Array* mdata, Map* msyms, Array* mdataSyms, Array* mfix)
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
            return;
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
                if (msyms.get((Hashable*)f.symbol()) != (Object*)0)
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
