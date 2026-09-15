// MachOLink.xc — merge explicit objects and pull archive members into the
// arm64 assembler's own model, then give the ObjC metadata its section
// identity back. The mirror of xtcln-arm64's mergeMachOInputs /
// repartitionObjcSections (bug 138) — the reference and this must lay the
// merged image out byte for byte alike, which is what bin-diff compares.
//
// Shared by the EXECUTABLE and the DYLIB paths, because a second copy of
// relocation merging is the kind that drifts.

#import "Foundation.xc"
#import "Arm64Asm.xc"
#import "MachOObject.xc"

class MachOLink
    {
    String* _why;
    u32 _rc;           // 0 merged; 1 error (reported in why); 2 a reloc the in-house link cannot express
    Array* _gotFixups; // Arm64Fixup@ — GOT refs, resolved after the pull settles

    void init(void)
        {
        _rc = (u32)0;
        _gotFixups = new Array();
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

    // The merge. `objectFiles` (paths) go in FIRST and forced — a .o on the
    // command line is a statement that it belongs in the image; archive
    // members join only when something still undefined needs them, to a
    // fixpoint. Symbols land in `msyms` (data ones also in `mdataSyms`),
    // fixups in `mfix`, ObjC runs (image coordinates) in `mObjc`.
    void merge(Array* objectFiles, Array* archives,
               Array* mtext, Array* mdata, Map* msyms, Array* mdataSyms,
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
                u32 base = mtext.count();
                MachOLink.appendData(mtext, obj.text());
                u32 dbase = mdata.count();
                if (obj.data().length() > (u32)0)
                    {
                    MachOLink.padArray(mdata, (u32)15);
                    dbase = mdata.count();
                    MachOLink.appendData(mdata, obj.data());
                    }
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
                progress = true;
                }
            }
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
            u32 insn = ((Number*)mtext.get(o)).asU32() | (((Number*)mtext.get(o + (u32)1)).asU32() << (u32)8) | (((Number*)mtext.get(o + (u32)2)).asU32() << (u32)16) | (((Number*)mtext.get(o + (u32)3)).asU32() << (u32)24);
            u32 add = (u32)$91000000 | (((insn >> (u32)5) & (u32)$1F) << (u32)5) | (insn & (u32)$1F);
            mtext.set(o, (Object*)Number.withU32(add & (u32)$FF));
            mtext.set(o + (u32)1, (Object*)Number.withU32((add >> (u32)8) & (u32)$FF));
            mtext.set(o + (u32)2, (Object*)Number.withU32((add >> (u32)16) & (u32)$FF));
            mtext.set(o + (u32)3, (Object*)Number.withU32((add >> (u32)24) & (u32)$FF));
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
    static Array* repartitionObjc(Array* mdata, Array* ranges, Map* msyms, Array* mdataSyms, Array* mfix)
        {
        Array* sections = new Array();
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
        u32 total = mdata.count();
        Array* owned = new Array(); // Number(0/1) per byte
        for (u32 i = (u32)0; i < total; i = i + (u32)1)
            owned.add((Object*)Number.withU32((u32)0));
        for (u32 i = (u32)0; i < sorted.count(); i = i + (u32)1)
            {
            MachOObjcRange* r = (MachOObjcRange*)sorted.get(i);
            if (r.off() + r.size() > total)
                return new Array(); // malformed; leave it alone
            for (u32 k = r.off(); k < r.off() + r.size(); k = k + (u32)1)
                owned.set(k, (Object*)Number.withU32((u32)1));
            }
        // 2. Lay the new blob out. moves: (oldStart, len, newStart) triples.
        Array* out = new Array();
        Array* moves = new Array();
        u32 i = (u32)0;
        while (i < total)
            {
            if (((Number*)owned.get(i)).asU32() != (u32)0)
                {
                i = i + (u32)1;
                continue;
                }
            u32 run = i;
            while (i < total && ((Number*)owned.get(i)).asU32() == (u32)0)
                i = i + (u32)1;
            // Bug 140: a run is re-laid at the same offset modulo 16 it had,
            // so nothing inside it loses its alignment when an odd-sized
            // ObjC run before it is pulled out (the reference's rule).
            while ((out.count() & (u32)15) != (run & (u32)15))
                out.add((Object*)Number.withU32((u32)0));
            MachOLink.addMove(moves, run, i - run, out.count());
            for (u32 k = run; k < i; k = k + (u32)1)
                out.add(mdata.get(k));
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
            u32 start = out.count();
            Array* runs = (Array*)byName.get((Hashable*)nm);
            MachOObjcRange* first = (MachOObjcRange*)runs.get((u32)0);
            for (u32 q = (u32)0; q < runs.count(); q = q + (u32)1)
                {
                MachOObjcRange* r = (MachOObjcRange*)runs.get(q);
                if (r.size() == (u32)0)
                    continue;
                MachOLink.addMove(moves, r.off(), r.size(), out.count());
                for (u32 b = r.off(); b < r.off() + r.size(); b = b + (u32)1)
                    out.add(mdata.get(b));
                }
            sections.add((Object*)MachOObjcRange.with(nm, first.seg(), first.flags(), start, out.count() - start));
            }
        // 3. Move everything that names a byte position.
        for (u32 k = (u32)0; k < mdataSyms.count(); k = k + (u32)1)
            {
            String* nm = (String*)mdataSyms.get(k);
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
        mdata.removeAll();
        for (u32 k = (u32)0; k < out.count(); k = k + (u32)1)
            mdata.add(out.get(k));
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
