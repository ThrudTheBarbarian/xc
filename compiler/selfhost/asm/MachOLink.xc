// MachOLink.xc — merge explicit objects and pull archive members into the
// arm64 assembler's own model, then give the ObjC metadata its section
// identity back. The mirror of xtcln-arm64's mergeMachOInputs /
// repartitionObjcSections (bug 138) — the reference and this must lay the
// merged image out byte for byte alike, which is what bin-diff compares.
//
// Shared by the EXECUTABLE and the DYLIB paths, because a second copy of
// relocation merging is the kind that drifts.

#import "Foundation.xc"
#import <Arm64Asm>
#import <SectionBytes>
#import "Arm64AsmDefs.xc"
#import <MachOObject>
#import "MachOObjectDefs.xc"

class MachOLink
    {
    String* _why;
    u32 _rc;           // 0 merged; 1 error (reported in why); 2 a reloc the in-house link cannot express
    Array* _gotFixups; // Arm64Fixup@ — GOT refs, resolved after the pull settles

    SectionBytes* _objModInit; // the objects' constructor lists, one after another
    Array* _objModInitFix; // Arm64Fixup@ against _objModInit

    void init(void)
        {
        _rc = (u32)0;
        _gotFixups = new Array();
        _objModInit = new SectionBytes();
        _objModInitFix = new Array();
        }

    SectionBytes* objModInit(void)
        {
        return _objModInit;
        }

    Array* objModInitFix(void)
        {
        return _objModInitFix;
        }

    // One object's constructor list, appended with its pointers as fixups.
    bool mergeModInit(MachOObject* obj, u32 oi)
        {
        Data* mi = obj.modInit();
        if (mi.length() == (u32)0)
            return true;
        while ((_objModInit.length() & (u32)7) != (u32)0)
            _objModInit.appendByte((u8)0);
        u32 mbase = _objModInit.length();
        for (u32 k = (u32)0; k < mi.length(); k = k + (u32)1)
            _objModInit.appendByte(mi.byteAt(k));
        Array* ml = obj.modInitRelocs();
        for (u32 k = (u32)0; k < ml.count(); k = k + (u32)1)
            {
            MachOReloc* r = (MachOReloc*)ml.get(k);
            if (r.type() == (u32)0 && r.ext() != (u32)0 && r.symnum() < obj.symnames().count())
                {
                MachOSymDef* sd = (MachOSymDef*)obj.symdefs().get(r.symnum());
                _objModInitFix.add((Object*)Arm64Fixup.make(mbase + r.off(), (u32)FIXUP_POINTER64,
                                                            MachOLink.taggedSym(sd, oi), (u32)0));
                continue;
                }
            Stdio.printf("xcc-ln-arm64: unhandled constructor relocation (type %lu, extern %lu)\n",
                         (u32)r.type(), (u32)r.ext());
            _why = String.withCString("unhandled constructor relocation");
            _rc = (u32)2;
            return false;
            }
        return true;
        }
    u32 rc(void)
        {
        return _rc;
        }
    String* why(void)
        {
        return _why;
        }

    // A symbol reference in a pulled object resolves to its real name if
    // external or undefined (cross-object / import), or a per-object-unique
    // name if it is a LOCAL definition (`l_.str` — Mach-O emits its relocs as
    // r_extern with a symtab index, but the symbol itself is non-external and
    // would clash across members).
    static String* taggedSym(MachOSymDef* sd, u32 oi)
        {
        bool localDef = !sd.ext() && sd.where() != (u32)0;
        if (!localDef)
            return sd.name();
        String* t = String.withCString("__L");
        t.append(Number.withU32(oi).description());
        t.appendCString("$");
        t.append(sd.name());
        return t;
        }

    static u32 insnAt(Data* t, u32 off)
        {
        return (u32)t.byteAt(off) | ((u32)t.byteAt(off + (u32)1) << (u32)8) | ((u32)t.byteAt(off + (u32)2) << (u32)16) | ((u32)t.byteAt(off + (u32)3) << (u32)24);
        }

    // One __text relocation of a pulled object → a fixup against the merged
    // image, or nil for a kind this linker does not express.
    static Arm64Fixup* relocFixup(MachOReloc* r, u32 base, MachOObject* obj, u32 oi)
        {
        if (r.ext() == (u32)0 || r.symnum() >= obj.symnames().count())
            return (Arm64Fixup*)0;
        u32 kind = (u32)0;
        if (r.type() == (u32)2)
            kind = (u32)FIXUP_BRANCH26;
        else if (r.type() == (u32)3)
            kind = (u32)FIXUP_PAGE21;
        else if (r.type() == (u32)4)
            kind = (u32)FIXUP_PAGEOFF12;
        else
            return (Arm64Fixup*)0;
        MachOSymDef* sd = (MachOSymDef*)obj.symdefs().get(r.symnum());
        u32 scale = (u32)0;
        // PAGEOFF12 patches an imm12: an unsigned-offset load/store scales it
        // by the access size, an `add` does not. Read the instruction.
        if (kind == (u32)FIXUP_PAGEOFF12 && r.off() + (u32)4 <= obj.text().length())
            {
            u32 insn = MachOLink.insnAt(obj.text(), r.off());
            if ((insn & (u32)$3B000000) == (u32)$39000000)
                {
                scale = insn >> (u32)30;
                if (scale == (u32)0 && ((insn >> (u32)26) & (u32)1) != (u32)0 && ((insn >> (u32)23) & (u32)1) != (u32)0)
                    scale = (u32)4; // 128-bit SIMD
                }
            }
        return Arm64Fixup.make(base + r.off(), kind, MachOLink.taggedSym(sd, oi), scale);
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

    // The merge. `objectFiles` (paths) go in FIRST and forced — a .o on the
    // command line is a statement that it belongs in the image; archive
    // members join only when something still undefined needs them, to a
    // fixpoint. Symbols land in `msyms` (data ones also in `mdataSyms`),
    // fixups in `mfix`, ObjC runs (image coordinates) in `mObjc`.
    void merge(Array* objectFiles, Array* archives,
               SectionBytes* mtext, SectionBytes* mdata, Map* msyms, Array* mdataSyms,
               Array* mfix, Array* mObjc)
        {
        _rc = (u32)0;
        if (objectFiles.count() == (u32)0 && archives.count() == (u32)0)
            return;
        Array* allObjs = new Array();
        Map* forced = new Map();
        for (u32 i = (u32)0; i < objectFiles.count(); i = i + (u32)1)
            {
            String* op = (String*)objectFiles.get(i);
            MachOObject* o = MachOObject.atPath(op);
            if (o == (MachOObject*)0)
                {
                _why = String.withCString("'").appending(op).appending(String.withCString("' is not a readable arm64 object"));
                _rc = (u32)1;
                return;
                }
            forced.set((Hashable*)Number.withU32(allObjs.count()), (Object*)Number.withU32((u32)1));
            allObjs.add((Object*)o);
            }
        for (u32 i = (u32)0; i < archives.count(); i = i + (u32)1)
            {
            String* ap = (String*)archives.get(i);
            Array* os = MachOObject.inArchive(ap);
            if (os == (Array*)0)
                {
                Stdio.printf("xcc: note: '%s' is not a parseable archive\n", ap.cString());
                continue;
                }
            for (u32 k = (u32)0; k < os.count(); k = k + (u32)1)
                allObjs.add(os.get(k));
            }
        Map* pulled = new Map();
        // Common-symbol resolution across objects (bug 177): size of the common
        // currently registered for a name, and the names a STRONG def claimed.
        Map* commonSizes = new Map();
        Map* strongDataDefs = new Map();
        bool progress = true;
        while (progress)
            {
            // What is still missing: a fixup whose symbol nothing defines.
            Map* needed = new Map();
            for (u32 i = (u32)0; i < mfix.count(); i = i + (u32)1)
                {
                Arm64Fixup* f = (Arm64Fixup*)mfix.get(i);
                if (f.symbol() == (String*)0 || f.symbol().byteLength() == (u32)0)
                    continue;
                if (msyms.get((Hashable*)f.symbol()) != (Object*)0)
                    continue;
                needed.set((Hashable*)f.symbol(), (Object*)Number.withU32((u32)1));
                }
            if (needed.count() == (u32)0 && forced.count() == (u32)0)
                break;
            progress = false;
            for (u32 oi = (u32)0; oi < allObjs.count(); oi = oi + (u32)1)
                {
                Number* key = Number.withU32(oi);
                if (pulled.get((Hashable*)key) != (Object*)0)
                    continue;
                MachOObject* obj = (MachOObject*)allObjs.get(oi);
                bool defines = forced.get((Hashable*)key) != (Object*)0;
                if (!defines)
                    defines = obj.definesAny(needed);
                if (!defines)
                    continue;
                forced.remove((Hashable*)key);
                pulled.set((Hashable*)key, (Object*)Number.withU32((u32)1));
                // Append __text (4-aligned) and the data blob (16-aligned: a
                // 16-byte literal inside the blob is only 16-aligned if the
                // blob itself starts so).
                MachOLink.padArray(mtext, (u32)3);
                u32 base = mtext.length();
                MachOLink.appendData(mtext, obj.text());
                u32 dbase = mdata.length();
                if (obj.data().length() > (u32)0)
                    {
                    MachOLink.padArray(mdata, obj.dataPageMask() > (u32)15 ? obj.dataPageMask() : (u32)15);
                    dbase = mdata.length();
                    MachOLink.appendData(mdata, obj.data());
                    }
                // An object that asked for more than 16-byte alignment (a page,
                // for a gpu-globals array): repartitionObjc keeps its base on
                // that boundary when it moves the data (#34).
                if (obj.data().length() > (u32)0 && obj.dataPageMask() > (u32)15)
                    mObjc.add((Object*)MachOObjcRange.with(String.withCString("@align"), String.withCString(""),
                                                           obj.dataPageMask() + (u32)1, dbase, (u32)0));
                Array* rs = obj.objcRanges();
                for (u32 k = (u32)0; k < rs.count(); k = k + (u32)1)
                    {
                    MachOObjcRange* r = (MachOObjcRange*)rs.get(k);
                    mObjc.add((Object*)MachOObjcRange.with(r.name(), r.seg(), r.flags(),
                                                           dbase + r.off(), r.size()));
                    }
                // Every defined symbol at its merged address: externals as-is,
                // locals under a per-object tag. Category-chain tables
                // (§4.3b) defined twice are a wrong CALL, not a missing symbol.
                Array* sdefs = obj.symdefs();
                for (u32 si = (u32)0; si < sdefs.count(); si = si + (u32)1)
                    {
                    MachOSymDef* sd = (MachOSymDef*)sdefs.get(si);
                    if (sd.where() == (u32)0 || sd.name().byteLength() == (u32)0)
                        continue;
                    String* nm = MachOLink.taggedSym(sd, oi);
                    u32 catAt = MachOLink.indexOf(nm, String.withCString("$cat$"));
                    if (catAt != (u32)$FFFFFFFF && msyms.get((Hashable*)nm) != (Object*)0)
                        {
                        String* cn = nm.substringBytes((u32)0, catAt);
                        if (cn.hasPrefix(String.withCString("_")))
                            cn = cn.substringFromByte((u32)1);
                        String* e = String.withCString("xcc-ln-arm64: error: two modules define category '");
                        e.append(nm.substringFromByte(catAt + (u32)5));
                        e.appendCString("' on class '");
                        e.append(cn);
                        e.appendCString("' ('");
                        e.append(nm);
                        e.appendCString("' defined twice). The category name is the extender's "
                                        "identity (separate-compilation §4.3b) — rename one, or compile "
                                        "both from one module\n");
                        Stdio.error(e);
                        _why = String.withCString("duplicate category");
                        _rc = (u32)1;
                        return;
                        }
                    if (nm.hasSuffix(String.withCString("$cat")) && msyms.get((Hashable*)nm) != (Object*)0)
                        {
                        String* cn = nm.substringBytes((u32)0, nm.byteLength() - (u32)4);
                        if (cn.hasPrefix(String.withCString("_")))
                            cn = cn.substringFromByte((u32)1);
                        String* e = String.withCString("xcc-ln-arm64: error: class '");
                        e.append(cn);
                        e.appendCString("' is compiled into two modules ('");
                        e.append(nm);
                        e.appendCString("', its category-chain table, defined twice)\n");
                        Stdio.error(e);
                        _why = String.withCString("class in two modules");
                        _rc = (u32)1;
                        return;
                        }
                    if (sd.where() == (u32)1)
                        msyms.set((Hashable*)nm, (Object*)Number.withU32(base + sd.off()));
                    else
                        {
                        // Common vs strong resolution (bug 177): a strong def
                        // beats any common; among commons the LARGEST size wins
                        // whatever the link order. obj.commons() gives this def's
                        // size when it is itself a common.
                        Object* cszO = obj.commons().get((Hashable*)sd.name());
                        if (cszO != (Object*)0)
                            {
                            u32 csz = ((Number*)cszO).asU32();
                            Object* have = commonSizes.get((Hashable*)nm);
                            if (strongDataDefs.get((Hashable*)nm) != (Object*)0)
                                {
                                // a strong def already claimed it
                                }
                            else if (have != (Object*)0 && ((Number*)have).asU32() >= csz)
                                {
                                // a same-or-larger common already registered
                                }
                            else
                                {
                                msyms.set((Hashable*)nm, (Object*)Number.withU32(dbase + sd.off()));
                                mdataSyms.add((Object*)nm);
                                commonSizes.set((Hashable*)nm, (Object*)Number.withU32(csz));
                                }
                            }
                        else
                            {
                            msyms.set((Hashable*)nm, (Object*)Number.withU32(dbase + sd.off()));
                            mdataSyms.add((Object*)nm);
                            strongDataDefs.set((Hashable*)nm, (Object*)Number.withU32((u32)1));
                            commonSizes.remove((Hashable*)nm);
                            }
                        }
                    }
                // __text relocations → fixups. An unhandled kind FAILS the
                // link: there is no clang behind this driver to retry with.
                i32 pendAddend = (i32)0;
                Array* rl = obj.relocs();
                for (u32 k = (u32)0; k < rl.count(); k = k + (u32)1)
                    {
                    MachOReloc* r = (MachOReloc*)rl.get(k);
                    // ARM64_RELOC_ADDEND
                    if (r.type() == (u32)10)
                        {
                        pendAddend = (i32)r.symnum();
                        continue;
                        }
                    if ((r.type() == (u32)5 || r.type() == (u32)6) && r.ext() != (u32)0)
                        {
                        if (r.symnum() >= obj.symnames().count())
                            {
                            _why = String.withCString("bad GOT symnum");
                            _rc = (u32)1;
                            return;
                            }
                        MachOSymDef* sd = (MachOSymDef*)obj.symdefs().get(r.symnum());
                        Arm64Fixup* gf = Arm64Fixup.make(base + r.off(),
                                                         r.type() == (u32)5 ? (u32)FIXUP_GOTPAGE21 : (u32)FIXUP_GOTPAGEOFF12,
                                                         MachOLink.taggedSym(sd, oi), (u32)0);
                        gf.setAddend(pendAddend);
                        pendAddend = (i32)0;
                        mfix.add((Object*)gf);
                        _gotFixups.add((Object*)gf);
                        continue;
                        }
                    Arm64Fixup* f = MachOLink.relocFixup(r, base, obj, oi);
                    if (f != (Arm64Fixup*)0)
                        {
                        f.setAddend(pendAddend);
                        pendAddend = (i32)0;
                        mfix.add((Object*)f);
                        continue;
                        }
                    Stdio.printf("xcc-ln-arm64: unhandled static-archive relocation (type %lu, extern %lu)\n",
                                 (u32)r.type(), (u32)r.ext());
                    _why = String.withCString("unhandled relocation");
                    _rc = (u32)2;
                    return;
                    }
                // DATA relocations: an UNSIGNED slot is a `.quad <symbol>`
                // pointer — the assembler's own Pointer64 fixup.
                Array* dl = obj.dataRelocs();
                for (u32 k = (u32)0; k < dl.count(); k = k + (u32)1)
                    {
                    MachOReloc* r = (MachOReloc*)dl.get(k);
                    if (r.type() == (u32)0 && r.ext() != (u32)0 && r.symnum() < obj.symnames().count())
                        {
                        MachOSymDef* sd = (MachOSymDef*)obj.symdefs().get(r.symnum());
                        mfix.add((Object*)Arm64Fixup.make(dbase + r.off(), (u32)FIXUP_POINTER64,
                                                          MachOLink.taggedSym(sd, oi), (u32)0));
                        continue;
                        }
                    Stdio.printf("xcc-ln-arm64: unhandled static-archive DATA relocation (type %lu, extern %lu)\n",
                                 (u32)r.type(), (u32)r.ext());
                    _why = String.withCString("unhandled data relocation");
                    _rc = (u32)2;
                    return;
                    }
                // The object's load-time constructors join the image's own list,
                // which the writer puts at the end of __data as its
                // S_MOD_INIT_FUNC_POINTERS section.
                if (!mergeModInit(obj, oi))
                    return;
                progress = true;
                }
            }
        MachOLink.selectorStubs(mtext, mdata, msyms, mdataSyms, mfix, mObjc);
        // GOT references, now that the pull has settled: a target DEFINED here
        // needs no GOT — relax `adrp x,s@GOTPAGE; ldr x,[x,s@GOTPAGEOFF]` to
        // `adrp x,s@PAGE; add x,x,s@PAGEOFF` (rewriting the ldr into an add).
        for (u32 i = (u32)0; i < _gotFixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* gf = (Arm64Fixup*)_gotFixups.get(i);
            if (msyms.get((Hashable*)gf.symbol()) == (Object*)0)
                continue; // stays a data import
            if (gf.kind() == (u32)FIXUP_GOTPAGE21)
                {
                gf.setKind((u32)FIXUP_PAGE21);
                continue;
                }
            gf.setKind((u32)FIXUP_PAGEOFF12);
            gf.setScale((u32)0);
            u32 o = gf.offset();
            u32 insn = (u32)mtext.byteAt(o) | ((u32)mtext.byteAt(o + (u32)1) << (u32)8) | ((u32)mtext.byteAt(o + (u32)2) << (u32)16) | ((u32)mtext.byteAt(o + (u32)3) << (u32)24);
            u32 add = (u32)$91000000 | (((insn >> (u32)5) & (u32)$1F) << (u32)5) | (insn & (u32)$1F);
            mtext.setByteAt(o, (u8)(add & (u32)$FF));
            mtext.setByteAt(o + (u32)1, (u8)((add >> (u32)8) & (u32)$FF));
            mtext.setByteAt(o + (u32)2, (u8)((add >> (u32)16) & (u32)$FF));
            mtext.setByteAt(o + (u32)3, (u8)((add >> (u32)24) & (u32)$FF));
            }
        }

    static void appendWord(SectionBytes* t, u32 w)
        {
        t.appendByte((u8)(w & (u32)$FF));
        t.appendByte((u8)((w >> (u32)8) & (u32)$FF));
        t.appendByte((u8)((w >> (u32)16) & (u32)$FF));
        t.appendByte((u8)((w >> (u32)24) & (u32)$FF));
        }

    // clang's Objective-C selector stubs (#40): a call to `_objc_msgSend$sel`
    // that nothing defines is a stub Apple's linker makes, so this one makes
    // it too. Each selector gets its name in __objc_methname, a slot in
    // __objc_selrefs pointing at the name (the runtime registers it at load
    // and writes the selector back), and a stub under the call's name:
    // `adrp x1, ref@PAGE; ldr x1, [x1, ref@PAGEOFF]; b _objc_msgSend`.
    // Selectors go in the order their first call appears among the fixups;
    // the reference linker makes the same bytes.
    static void selectorStubs(SectionBytes* mtext, SectionBytes* mdata, Map* msyms, Array* mdataSyms,
                              Array* mfix, Array* mObjc)
        {
        String* pre = String.withCString("_objc_msgSend$");
        Array* stubs = new Array();
        Map* seen = new Map();
        for (u32 i = (u32)0; i < mfix.count(); i = i + (u32)1)
            {
            String* s = ((Arm64Fixup*)mfix.get(i)).symbol();
            if (s == (String*)0 || s.byteLength() <= pre.byteLength() || !s.hasPrefix(pre))
                continue;
            if (msyms.get((Hashable*)s) != (Object*)0 || seen.get((Hashable*)s) != (Object*)0)
                continue;
            seen.set((Hashable*)s, (Object*)Number.withU32((u32)1));
            stubs.add((Object*)s);
            }
        if (stubs.count() == (u32)0)
            return;
        Array* names = new Array();
        Array* refs = new Array();
        MachOLink.padArray(mdata, (u32)15);
        u32 nbase = mdata.length();
        for (u32 k = (u32)0; k < stubs.count(); k = k + (u32)1)
            {
            String* sel = ((String*)stubs.get(k)).substringFromByte(pre.byteLength());
            String* nm = String.withCString("__xc_selname$").appending(sel);
            msyms.set((Hashable*)nm, (Object*)Number.withU32(mdata.length()));
            mdataSyms.add((Object*)nm);
            names.add((Object*)nm);
            for (u32 b = (u32)0; b < sel.byteLength(); b = b + (u32)1)
                mdata.appendByte(sel.byteAt(b));
            mdata.appendByte((u8)0);
            refs.add((Object*)String.withCString("__xc_selref$").appending(sel));
            }
        mObjc.add((Object*)MachOObjcRange.with(String.withCString("__objc_methname"), String.withCString("__TEXT"),
                                               (u32)2, nbase, mdata.length() - nbase));
        MachOLink.padArray(mdata, (u32)7);
        u32 rbase = mdata.length();
        for (u32 k = (u32)0; k < stubs.count(); k = k + (u32)1)
            {
            String* ref = (String*)refs.get(k);
            msyms.set((Hashable*)ref, (Object*)Number.withU32(mdata.length()));
            mdataSyms.add((Object*)ref);
            mfix.add((Object*)Arm64Fixup.make(mdata.length(), (u32)FIXUP_POINTER64, (String*)names.get(k), (u32)0));
            for (u32 b = (u32)0; b < (u32)8; b = b + (u32)1)
                mdata.appendByte((u8)0);
            }
        // S_LITERAL_POINTERS, no dead strip: what clang gives its own selrefs.
        mObjc.add((Object*)MachOObjcRange.with(String.withCString("__objc_selrefs"), String.withCString("__DATA"),
                                               (u32)$10000005, rbase, mdata.length() - rbase));
        MachOLink.padArray(mtext, (u32)3);
        for (u32 k = (u32)0; k < stubs.count(); k = k + (u32)1)
            {
            String* ref = (String*)refs.get(k);
            u32 at = mtext.length();
            msyms.set((Hashable*)stubs.get(k), (Object*)Number.withU32(at));
            mfix.add((Object*)Arm64Fixup.make(at, (u32)FIXUP_PAGE21, ref, (u32)0));
            mfix.add((Object*)Arm64Fixup.make(at + (u32)4, (u32)FIXUP_PAGEOFF12, ref, (u32)3));
            mfix.add((Object*)Arm64Fixup.make(at + (u32)8, (u32)FIXUP_BRANCH26, String.withCString("_objc_msgSend"), (u32)0));
            MachOLink.appendWord(mtext, (u32)$90000001);  // adrp x1, ref@PAGE
            MachOLink.appendWord(mtext, (u32)$F9400021);  // ldr x1, [x1, ref@PAGEOFF]
            MachOLink.appendWord(mtext, (u32)$14000000);  // b _objc_msgSend
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

    // Bug 069: give the ObjC metadata its section identity back. The blob
    // interleaves ObjC runs with ordinary data, so the bytes are REGROUPED:
    // ordinary data first in its original order, then each __objc_* section
    // gathered from every object it came from — and everything naming a byte
    // position (data symbols, Pointer64 fixups) moves with it. Returns the
    // section table for the writer, in FINAL blob coordinates; empty when
    // there is no ObjC content, in which case nothing moves.
    // The class tables' runs (#34): each module's back end puts its vtables
    // and itables between `___xt_vtbl_lo` and `___xt_vtbl_hi` (a merged
    // object's pair carries its tag, `__L<n>$___xt_vtbl_lo`). Each run becomes
    // a range of the __xt_vtbl section, which repartitionObjc gathers into one;
    // a checked build's vtable check finds each image's tables by it.
    static void addVtblRuns(Map* msyms, Array* mObjc)
        {
        String* lo = String.withCString("___xt_vtbl_lo");
        String* lot = String.withCString("$___xt_vtbl_lo");
        String* hi = String.withCString("___xt_vtbl_hi");
        Array* ks = msyms.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            {
            String* l = (String*)ks.get(i);
            if (!l.equals(lo) && !(l.hasPrefix(String.withCString("__L")) && l.hasSuffix(lot)))
                continue;
            String* h = l.substringBytes((u32)0, l.byteLength() - lo.byteLength());
            h.append(hi);
            Object* hv = msyms.get((Hashable*)h);
            if (hv == (Object*)0)
                continue;
            u32 a = ((Number*)msyms.get((Hashable*)l)).asU32();
            u32 b = ((Number*)hv).asU32();
            if (b <= a)
                continue;
            mObjc.add((Object*)MachOObjcRange.with(String.withCString("__xt_vtbl"), String.withCString("__DATA"),
                                                   (u32)0, a, b - a));
            // The end label sits just past the run, often at the very end of
            // the data, where no move of the repartition covers it. It has
            // done its job; put it at the run's start, which moves with it.
            msyms.set((Hashable*)h, (Object*)Number.withU32(a));
            }
        }

    static Array* repartitionObjc(SectionBytes* mdata, Array* rangesIn, Map* msyms, Array* mdataSyms, Array* mfix)
        {
        Array* sections = new Array();
        // The merge's alignment marks are not sections: set them aside.
        Array* anchors = new Array();
        Array* ranges = new Array();
        for (u32 i = (u32)0; i < rangesIn.count(); i = i + (u32)1)
            {
            MachOObjcRange* r = (MachOObjcRange*)rangesIn.get(i);
            if (r.name().equals(String.withCString("@align")))
                anchors.add((Object*)r);
            else
                ranges.add((Object*)r);
            }
        if (ranges.count() == (u32)0)
            return sections;
        // 1. Sort the runs by position (stable insertion — few runs).
        Array* sorted = new Array();
        for (u32 i = (u32)0; i < ranges.count(); i = i + (u32)1)
            {
            MachOObjcRange* r = (MachOObjcRange*)ranges.get(i);
            u32 at = sorted.count();
            for (u32 k = (u32)0; k < sorted.count(); k = k + (u32)1)
                if (((MachOObjcRange*)sorted.get(k)).off() > r.off())
                    {
                    at = k;
                    break;
                    }
            sorted.insert(at, (Object*)r);
            }
        u32 total = mdata.length();
        for (u32 i = (u32)0; i < sorted.count(); i = i + (u32)1)
            {
            MachOObjcRange* r = (MachOObjcRange*)sorted.get(i);
            if (r.off() + r.size() > total)
                return new Array(); // malformed; leave it alone
            }
        // 2. Lay the new blob out. moves: (oldStart, len, newStart) triples.
        // The ordinary data is what lies between the runs, taken gap by gap
        // (the runs are sorted and do not overlap); a byte map of the whole
        // blob cost an object per byte once every image had a vtable run.
        SectionBytes* out = new SectionBytes();
        Array* moves = new Array();
        u32 cursor = (u32)0;
        for (u32 g = (u32)0; g <= sorted.count(); g = g + (u32)1)
            {
            u32 gapEnd = total;
            if (g < sorted.count())
                {
                MachOObjcRange* r = (MachOObjcRange*)sorted.get(g);
                if (r.size() == (u32)0)
                    continue;
                gapEnd = r.off();
                }
            if (gapEnd > cursor)
                {
                u32 run = cursor;
                // Bug 140: a run is re-laid at the same offset modulo 16 it
                // had, so nothing inside it loses its alignment when an
                // odd-sized ObjC run before it is pulled out (the reference's
                // rule).
                // More than 16 where an object the run holds asked for it
                // (its "@align" mark): a page-aligned global array stays on
                // a page, or Metal copies it instead of sharing it (#34).
                u32 al = (u32)16;
                for (u32 q = (u32)0; q < anchors.count(); q = q + (u32)1)
                    {
                    MachOObjcRange* an = (MachOObjcRange*)anchors.get(q);
                    if (an.off() >= run && an.off() < gapEnd && an.flags() > al)
                        al = an.flags();
                    }
                while ((out.length() & (al - (u32)1)) != (run & (al - (u32)1)))
                    out.appendByte((u8)((u32)0));
                MachOLink.addMove(moves, run, gapEnd - run, out.length());
                for (u32 k = run; k < gapEnd; k = k + (u32)1)
                    out.appendByte(mdata.byteAt(k));
                }
            if (g < sorted.count())
                {
                MachOObjcRange* r = (MachOObjcRange*)sorted.get(g);
                if (r.off() + r.size() > cursor)
                    cursor = r.off() + r.size();
                }
            }
        Array* order = new Array(); // first-seen names
        Map* byName = new Map();
        for (u32 k = (u32)0; k < sorted.count(); k = k + (u32)1)
            {
            MachOObjcRange* r = (MachOObjcRange*)sorted.get(k);
            Object* lst = byName.get((Hashable*)r.name());
            if (lst == (Object*)0)
                {
                lst = (Object*)new Array();
                byName.set((Hashable*)r.name(), lst);
                order.add((Object*)r.name());
                }
            ((Array*)lst).add((Object*)r);
            }
        for (u32 k = (u32)0; k < order.count(); k = k + (u32)1)
            {
            String* nm = (String*)order.get(k);
            MachOLink.padArray(out, (u32)7);
            u32 start = out.length();
            Array* runs = (Array*)byName.get((Hashable*)nm);
            MachOObjcRange* first = (MachOObjcRange*)runs.get((u32)0);
            for (u32 q = (u32)0; q < runs.count(); q = q + (u32)1)
                {
                MachOObjcRange* r = (MachOObjcRange*)runs.get(q);
                if (r.size() == (u32)0)
                    continue;
                MachOLink.addMove(moves, r.off(), r.size(), out.length());
                for (u32 b = r.off(); b < r.off() + r.size(); b = b + (u32)1)
                    out.appendByte(mdata.byteAt(b));
                }
            sections.add((Object*)MachOObjcRange.with(nm, first.seg(), first.flags(), start, out.length() - start));
            }
        // 3. Move everything that names a byte position. Each name once:
        // mdataSyms lists a name every time an object defines it (the
        // standard library's classes are in every object of a split build),
        // and a second move took it on from where the first put it.
        Set* moved = new Set();
        for (u32 k = (u32)0; k < mdataSyms.count(); k = k + (u32)1)
            {
            String* nm = (String*)mdataSyms.get(k);
            if (moved.contains((Hashable*)nm))
                continue;
            moved.add((Hashable*)nm);
            Object* v = msyms.get((Hashable*)nm);
            if (v == (Object*)0)
                continue;
            u32 nv = MachOLink.remap(moves, ((Number*)v).asU32());
            if (nv != (u32)$FFFFFFFF)
                msyms.set((Hashable*)nm, (Object*)Number.withU32(nv));
            }
        for (u32 k = (u32)0; k < mfix.count(); k = k + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)mfix.get(k);
            if (f.kind() != (u32)FIXUP_POINTER64)
                continue; // the only data-addressing kind
            u32 nv = MachOLink.remap(moves, f.offset());
            if (nv != (u32)$FFFFFFFF)
                f.setOffset(nv);
            }
        mdata.setContents(out);
        return sections;
        }

    static void addMove(Array* moves, u32 st, u32 len, u32 nw)
        {
        Array* m = new Array();
        m.add((Object*)Number.withU32(st));
        m.add((Object*)Number.withU32(len));
        m.add((Object*)Number.withU32(nw));
        moves.add((Object*)m);
        }
    static u32 remap(Array* moves, u32 old)
        {
        for (u32 i = (u32)0; i < moves.count(); i = i + (u32)1)
            {
            Array* m = (Array*)moves.get(i);
            u32 st = ((Number*)m.get((u32)0)).asU32();
            u32 len = ((Number*)m.get((u32)1)).asU32();
            if (old >= st && old < st + len)
                return ((Number*)m.get((u32)2)).asU32() + (old - st);
            }
        return (u32)$FFFFFFFF;
        }
    }
