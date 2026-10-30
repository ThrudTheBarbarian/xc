// ElfLinkArm64.xc — merge ELF aarch64 objects and archive members into the
// arm64 assembler's model for the android link.
// =================================================================
//
// The android twin of MachOLink (bug 138): a C library built by the NDK's
// clang — Mbed TLS behind libtls, say — joins an `-A android` image the way a
// Mach-O archive joins a macOS one. ElfObject reads each member (the x86-64
// link's reader; it is machine-independent), the blobs are appended to the
// text and data the assembler produced, the symbols land at their merged
// offsets, and each RELA becomes one of the six fixup kinds ElfArm64 already
// resolves: a branch, an adrp page, a lo12 offset (scaled by the access size
// the relocation type names), a GOT page or offset, or a pointer word.
//
// The rules carried from the two merges this mirrors:
//
//   * A LOCAL definition is tagged per object (`__L<n>$name`), a SECTION
//     symbol, which has no name, as `__L<n>$sec<index>`; an external keeps its
//     name. Every relocation against either is tagged the same way.
//   * Archive members join only when something still undefined needs them,
//     to a fixpoint; a .o named on the command line joins regardless.
//   * STRONG beats WEAK whatever the order; two strong definitions are an
//     error, not a silent override.
//   * A GOT reference to a symbol the image defines is relaxed to adrp/add
//     after the pull settles, as MachOLink does: the writer makes GOT slots
//     for imports alone.
//   * `.eh_frame` travels in the data blob and its PC-relative words are
//     left as they are: nothing unwinds through C frames here. A PC-relative
//     word anywhere else (a switch's jump table in .rodata) becomes a
//     FIXUP_PREL32 the writer settles, both ends being in the image.

#import "Foundation.xc"
#import <Arm64Asm>
#import "Arm64AsmDefs.xc"
#import <ElfObject>
#import <ArArchive>
#import <ElfArm64>
#import "ElfArm64Defs.xc"

#import "ElfLinkArm64Defs.xc"

class ElfLinkArm64
    {
    String* _why;
    u32 _rc;            // 0 merged; 1 error (reported in why)
    Array* _gotFixups;  // Arm64Fixup@ — GOT refs, relaxed after the pull settles

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
    void fail(String* m)
        {
        if (_rc == (u32)0)
            {
            _rc = (u32)1;
            _why = m;
            }
        }

    static String* taggedSym(ElfSymDef* sd, u32 oi, u32 si)
        {
        bool localDef = !sd.ext() && sd.where() != (u32)0;
        if (!localDef)
            return sd.name();
        String* t = String.withCString("__L");
        t.append(Number.withU32(oi).description());
        t.appendCString("$");
        if (sd.name() == (String*)0 || sd.name().byteLength() == (u32)0)
            {
            t.appendCString("sec");
            t.append(Number.withU32(si).description());
            }
        else
            t.append(sd.name());
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
    // Whether the object defines something still wanted: wanted at the
    // start of this pass AND not defined by a member pulled earlier in it,
    // or two archives holding the same member (Mbed TLS ships libmbedcrypto
    // and libtfpsacrypto as one) would both be pulled, and clash.
    static bool definesAny(ElfObject* o, Map* needed, Map* msyms)
        {
        Array* names = o.definedNames();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            if (needed.get((Hashable*)names.get(i)) != (Object*)0 && msyms.get((Hashable*)names.get(i)) == (Object*)0)
                return true;
        return false;
        }

    // The fixup kind and lo12 scale a text relocation type maps to; kind
    // $FFFFFFFF for one the writer cannot express.
    static u32 kindOf(u32 type)
        {
        if (type == (u32)RA64_CALL26 || type == (u32)RA64_JUMP26)
            return (u32)FIXUP_BRANCH26;
        if (type == (u32)RA64_ADR_PREL_PG_HI21)
            return (u32)FIXUP_PAGE21;
        if (type == (u32)RA64_ADD_ABS_LO12_NC || type == (u32)RA64_LDST8_ABS_LO12_NC
            || type == (u32)RA64_LDST16_ABS_LO12_NC || type == (u32)RA64_LDST32_ABS_LO12_NC
            || type == (u32)RA64_LDST64_ABS_LO12_NC || type == (u32)RA64_LDST128_ABS_LO12_NC)
            return (u32)FIXUP_PAGEOFF12;
        if (type == (u32)RA64_ADR_GOT_PAGE)
            return (u32)FIXUP_GOTPAGE21;
        if (type == (u32)RA64_LD64_GOT_LO12_NC)
            return (u32)FIXUP_GOTPAGEOFF12;
        return (u32)$FFFFFFFF;
        }
    static u32 scaleOf(u32 type)
        {
        if (type == (u32)RA64_LDST16_ABS_LO12_NC) return (u32)1;
        if (type == (u32)RA64_LDST32_ABS_LO12_NC) return (u32)2;
        if (type == (u32)RA64_LDST64_ABS_LO12_NC) return (u32)3;
        if (type == (u32)RA64_LDST128_ABS_LO12_NC) return (u32)4;
        return (u32)0;
        }

    // The merge: `objectFiles` (paths) join first and forced, archive members
    // as something needs them. Symbols land in `msyms` (data ones also in
    // `mdataSyms`), fixups in `mfix`.
    void merge(Array* objectFiles, Array* archives,
               Array* mtext, Array* mdata, Map* msyms, Array* mdataSyms, Array* mfix)
        {
        _rc = (u32)0;
        if (objectFiles.count() == (u32)0 && archives.count() == (u32)0)
            return;
        // The program's own GOT references too: xcc reaches what another
        // file defines through the GOT (a C program's globals, which clang's
        // half defines), and once an object here defines it the image does.
        // Left as a GOT load, the writer resolved its ldr to the symbol
        // itself and loaded the variable's first word as its address.
        for (u32 i = (u32)0; i < mfix.count(); i = i + (u32)1)
            {
            Arm64Fixup* pf = (Arm64Fixup*)mfix.get(i);
            if (pf.kind() == (u32)FIXUP_GOTPAGE21 || pf.kind() == (u32)FIXUP_GOTPAGEOFF12)
                _gotFixups.add((Object*)pf);
            }
        Array* allObjs = new Array();
        Array* labels = new Array();
        Map* forced = new Map();
        for (u32 i = (u32)0; i < objectFiles.count(); i = i + (u32)1)
            {
            String* op = (String*)objectFiles.get(i);
            ElfObject* o = ElfObject.parse(Files.readData(op));
            if (o == (ElfObject*)0 || !o.ok())
                {
                fail(String.withCString("'").appending(op).appending(String.withCString("' is not a readable aarch64 ELF object")));
                return;
                }
            forced.set((Hashable*)Number.withU32(allObjs.count()), (Object*)Number.withU32((u32)1));
            allObjs.add((Object*)o);
            labels.add((Object*)op);
            }
        for (u32 i = (u32)0; i < archives.count(); i = i + (u32)1)
            {
            String* ap = (String*)archives.get(i);
            Array* ms = ArArchive.membersOfFile(ap);
            if (ms == (Array*)0)
                {
                Stdio.printf("xcc: note: '%s' is not a parseable archive\n", ap.cString());
                continue;
                }
            for (u32 k = (u32)0; k < ms.count(); k = k + (u32)1)
                {
                ArMember* m = (ArMember*)ms.get(k);
                ElfObject* o = ElfObject.parse(m.data());
                if (o == (ElfObject*)0 || !o.ok())
                    continue;   // the symbol index, or a member with no code
                allObjs.add((Object*)o);
                String* lb = String.withString(ap);
                lb.appendCString("(");
                lb.append(m.name());
                lb.appendCString(")");
                labels.add((Object*)lb);
                }
            }
        Map* pulled = new Map();
        Map* strongDefs = new Map();
        Map* weakDefs = new Map();
        bool progress = true;
        while (progress)
            {
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
                ElfObject* obj = (ElfObject*)allObjs.get(oi);
                bool defines = forced.get((Hashable*)key) != (Object*)0;
                if (!defines)
                    defines = ElfLinkArm64.definesAny(obj, needed, msyms);
                if (!defines)
                    continue;
                forced.remove((Hashable*)key);
                pulled.set((Hashable*)key, (Object*)Number.withU32((u32)1));
                String* label = (String*)labels.get(oi);
                if (obj.tls().length() > (u32)0 || obj.tlsRelocs().count() > (u32)0)
                    {
                    fail(String.withCString("thread-local storage in ").appending(label).appending(String.withCString(" (an android link takes none)")));
                    return;
                    }
                // The blobs: text 16-aligned, data at the largest alignment
                // any of its sections asked for.
                ElfLinkArm64.padArray(mtext, (u32)15);
                u32 base = mtext.count();
                ElfLinkArm64.appendData(mtext, obj.text());
                u32 dalign = obj.dataAlign() < (u32)16 ? (u32)16 : obj.dataAlign();
                ElfLinkArm64.padArray(mdata, dalign - (u32)1);
                u32 dbase = mdata.count();
                ElfLinkArm64.appendData(mdata, obj.data());
                // Every definition at its merged offset.
                Array* sdefs = obj.symdefs();
                for (u32 si = (u32)0; si < sdefs.count(); si = si + (u32)1)
                    {
                    ElfSymDef* sd = (ElfSymDef*)sdefs.get(si);
                    if (sd.where() == (u32)0)
                        continue;
                    String* nm = ElfLinkArm64.taggedSym(sd, oi, si);
                    if (nm.byteLength() == (u32)0)
                        continue;
                    bool have = msyms.get((Hashable*)nm) != (Object*)0;
                    if (have && sd.ext())
                        {
                        if (sd.weak())
                            continue;                                   // a definition stands already
                        if (strongDefs.get((Hashable*)nm) != (Object*)0)
                            {
                            fail(String.withCString("'").appending(nm).appending(String.withCString("' is defined twice, the second time in ")).appending(label));
                            return;
                            }
                        // strong over weak: fall through and replace
                        }
                    if (sd.where() == (u32)5)
                        {
                        // COMMON: one zeroed slot per name, where the first
                        // request puts it.
                        if (have)
                            continue;
                        u32 al = sd.align() < (u32)1 ? (u32)1 : sd.align();
                        ElfLinkArm64.padArray(mdata, al - (u32)1);
                        msyms.set((Hashable*)nm, (Object*)Number.withU32(mdata.count()));
                        for (u32 z = (u32)0; z < sd.size(); z = z + (u32)1)
                            mdata.add((Object*)Number.withU32((u32)0));
                        mdataSyms.add((Object*)nm);
                        weakDefs.set((Hashable*)nm, (Object*)Number.withU32((u32)1));
                        continue;
                        }
                    bool inData = sd.where() == (u32)2;
                    msyms.set((Hashable*)nm, (Object*)Number.withU32((inData ? dbase : base) + sd.off()));
                    if (inData && !ElfArm64.inArray(mdataSyms, nm))
                        mdataSyms.add((Object*)nm);
                    if (sd.ext() && !sd.weak())
                        strongDefs.set((Hashable*)nm, (Object*)Number.withU32((u32)1));
                    else if (sd.ext())
                        weakDefs.set((Hashable*)nm, (Object*)Number.withU32((u32)1));
                    }
                // Text relocations → fixups.
                Array* rl = obj.relocs();
                for (u32 k = (u32)0; k < rl.count(); k = k + (u32)1)
                    {
                    ElfReloc* r = (ElfReloc*)rl.get(k);
                    if (r.sym() >= sdefs.count())
                        {
                        fail(String.withCString("a relocation names no symbol in ").appending(label));
                        return;
                        }
                    u32 kind = ElfLinkArm64.kindOf(r.type());
                    if (kind == (u32)$FFFFFFFF)
                        {
                        String* m = String.withCString("unhandled aarch64 relocation type ");
                        m.append(Number.withU32(r.type()).description());
                        m.appendCString(" in ");
                        m.append(label);
                        fail(m);
                        return;
                        }
                    ElfSymDef* sd = (ElfSymDef*)sdefs.get(r.sym());
                    Arm64Fixup* f = Arm64Fixup.make(base + r.off(), kind,
                                                    ElfLinkArm64.taggedSym(sd, oi, r.sym()),
                                                    ElfLinkArm64.scaleOf(r.type()));
                    f.setAddend((i32)r.addend());
                    mfix.add((Object*)f);
                    if (kind == (u32)FIXUP_GOTPAGE21 || kind == (u32)FIXUP_GOTPAGEOFF12)
                        _gotFixups.add((Object*)f);
                    }
                // Data relocations: a pointer word, or an .eh_frame entry
                // left alone.
                Array* dl = obj.dataRelocs();
                for (u32 k = (u32)0; k < dl.count(); k = k + (u32)1)
                    {
                    ElfReloc* r = (ElfReloc*)dl.get(k);
                    if (r.sym() >= sdefs.count())
                        {
                        fail(String.withCString("a data relocation names no symbol in ").appending(label));
                        return;
                        }
                    if (r.type() == (u32)RA64_ABS64)
                        {
                        ElfSymDef* sd = (ElfSymDef*)sdefs.get(r.sym());
                        Arm64Fixup* f = Arm64Fixup.make(dbase + r.off(), (u32)FIXUP_POINTER64,
                                                        ElfLinkArm64.taggedSym(sd, oi, r.sym()), (u32)0);
                        f.setAddend((i32)r.addend());
                        mfix.add((Object*)f);
                        continue;
                        }
                    String* sec = obj.dataSectionNameAt(r.off());
                    if (sec != (String*)0 && sec.hasPrefix(String.withCString(".eh_frame")))
                        continue;
                    if (r.type() == (u32)RA64_PREL32)
                        {
                        // A jump table's `target - here` word: both ends are
                        // in this image, so the writer settles it.
                        ElfSymDef* sd = (ElfSymDef*)sdefs.get(r.sym());
                        Arm64Fixup* f = Arm64Fixup.make(dbase + r.off(), (u32)FIXUP_PREL32,
                                                        ElfLinkArm64.taggedSym(sd, oi, r.sym()), (u32)0);
                        f.setAddend((i32)r.addend());
                        mfix.add((Object*)f);
                        continue;
                        }
                    String* m = String.withCString("unhandled aarch64 data relocation type ");
                    m.append(Number.withU32(r.type()).description());
                    m.appendCString(" in ");
                    m.append(label);
                    if (sec != (String*)0)
                        {
                        m.appendCString(" section ");
                        m.append(sec);
                        }
                    fail(m);
                    return;
                    }
                progress = true;
                }
            }
        // GOT references to what the image defines: adrp/ldr → adrp/add.
        for (u32 i = (u32)0; i < _gotFixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* gf = (Arm64Fixup*)_gotFixups.get(i);
            if (msyms.get((Hashable*)gf.symbol()) == (Object*)0)
                continue;
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
    }
