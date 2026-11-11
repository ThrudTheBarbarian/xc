// ElfArm64.xc — write the aarch64 ELF image `-A android` runs.
// =================================================================
//
// The port of `XTElfArm64Writer`, and the ELF64/AArch64 twin of Elf64.xc's
// x86-64 static executable. Same job, different machine and a heavier shape:
// Android runs ET_DYN and nothing else, so an app is a PIE (PT_PHDR +
// PT_INTERP + an entry point) and a NativeActivity payload is a `.so` (SONAME,
// no entry). They differ by two program headers and a couple of dynamic tags,
// so one method writes both — pass an entry symbol for the executable, or 0.
//
// Being the whole-program linker, an intra-image reference is resolved here and
// never becomes a dynamic relocation. Three kinds survive to load time:
// R_AARCH64_RELATIVE for each `.quad <symbol>` — a vtable word, an absolute
// address the loader must bias — R_AARCH64_ABS64 for a `.quad` naming a symbol
// another library defines, and R_AARCH64_GLOB_DAT for each symbol imported
// from bionic or a library, reached from a 16-byte adrp/ldr/br thunk so the back
// end's direct `bl` needs no rewriting.
//
// As in the other writers, addresses are kept as 32-bit FILE OFFSETS and the
// high half of every 64-bit field is written as zero. Nothing here is mapped
// above 4 GB before the loader applies its bias, and the bias is added at run
// time, not by us.

#import "Foundation.xc"
#import <Arm64Asm>
#import <SectionBytes>
#import "Arm64AsmDefs.xc"

// 16 KB, not 4. Android 15 runs on devices with 16 KB pages and will not map a
// 4 KB-aligned segment; 16 KB is accepted on 4 KB devices too, so there is one
// right answer and this is it.
#import "ElfArm64Defs.xc"
#import "ElfLinkArm64Defs.xc"

class ElfArm64
    {
    Data* _out;
    bool _failed;
    String* _why;
    String* _interp;   // an executable's PT_INTERP (the reference's setInterpreter:)
    String* _runpath;  // a DT_RUNPATH, or 0 for none (the reference's setRunpath:)
    Map* _known;       // the symbols an executable may import, or 0: none checked (setKnownImports:)

    void init(void)
        {
        _out = new Data();
        _failed = false;
        _interp = String.withCString("/system/bin/linker64");
        _runpath = (String*)0;
        _known = (Map*)0;
        }

    // Android's linker64 unless set (glibc Linux: /lib/ld-linux-aarch64.so.1).
    void setInterp(String* path)
        {
        _interp = path;
        }

    // arm64 Linux: glibc's symbols (glibc-imports.map) and those of the
    // libraries the program links; any other import is an error naming it.
    // None by default (android checks nothing).
    void setKnownImports(Map* names)
        {
        _known = names;
        }

    // "$ORIGIN:<dir>..." for arm64 Linux; none by default, as Android's.
    void setRunpath(String* path)
        {
        _runpath = (path != (String*)0 && path.byteLength() > (u32)0) ? path : (String*)0;
        }

    Data* bytes(void)
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
        _out.appendByte((u8)(v & (u32)$FF));
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
    void p64(u32 v)
        {
        p32(v);
        p32((u32)0);
        }
    void padTo(u32 off)
        {
        if (_out.length() < off)
            _out.increaseLengthBy(off - _out.length());
        }

    static u32 roundUpTo(u32 v, u32 a)
        {
        return (v + a - (u32)1) & ~(a - (u32)1);
        }

    // Trailing zeros need not be stored: a PT_LOAD whose p_memsz exceeds its
    // p_filesz is zero-filled by the kernel, which is what .bss and a
    // zero-initialised array are.
    static u32 fileSizeOf(SectionBytes* d)
        {
        return d.fileLength();
        }

    // ── ET_REL: the object `-c` writes (arm64 Linux, android) ──────────
    //
    // Separate compilation on the aarch64 ELF rows: what ElfLinkArm64 reads
    // back at the link, and what a GNU or LLVM linker accepts. The sections
    // are the assembler's two blobs, .text and .data, and, when the module
    // has load-time constructors, an .init_array of their pointers (the link
    // runs them, as it runs a Mach-O object's __mod_init_func); then a RELA
    // table per patched section, the symbols and their strings.
    //
    // Every fixup naming a symbol becomes a relocation, whether this object
    // defines the symbol or not: the link places the sections. The kinds map
    // back the way ElfLinkArm64.kindOf reads them: a branch is CALL26, an adrp
    // page ADR_PREL_PG_HI21, a lo12 offset ADD_ABS_LO12_NC or the LDST type of
    // its access size, a GOT page and offset ADR_GOT_PAGE and LD64_GOT_LO12_NC,
    // a pointer word ABS64.
    Data* objectFromText(SectionBytes* text, SectionBytes* data, Map* symbols, Array* dataSyms,
                         Array* fixups, Array* exports, Map* commons,
                         SectionBytes* modInit, Array* modInitFix)
        {
        _out = new Data();
        _failed = false;
        if (data == (SectionBytes*)0)
            data = new SectionBytes();
        if (commons == (Map*)0)
            commons = new Map();
        if (modInit == (SectionBytes*)0)
            modInit = new SectionBytes();
        if (modInitFix == (Array*)0)
            modInitFix = new Array();

        // Locals first (ELF wants every STB_LOCAL before the globals, and
        // .symtab's sh_info at the first global), then defined globals, text
        // then data, then commons, then undefined. Sorted in each group, so two
        // builds of one input are the same bytes.
        Array* names = symbols.allKeys();
        ElfArm64.sortStrings(names);
        Array* locals = new Array();
        Array* defText = new Array();
        Array* defData = new Array();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* n = (String*)names.get(i);
            // No `L…` skip as in the Mach-O object: in the ELF spelling a
            // class named Lower is `Lower$init`, as an assembler label is
            // `L…`. A label nothing exports is a local symbol, which is right
            // for both.
            if (commons.get((Hashable*)n) != (Object*)0)
                continue;
            if (exports != (Array*)0 && !ElfArm64.inArray(exports, n))
                {
                locals.add((Object*)n);
                continue;
                }
            if (ElfArm64.inArray(dataSyms, n))
                defData.add((Object*)n);
            else
                defText.add((Object*)n);
            }
        Array* undef = new Array();
        for (u32 pass = (u32)0; pass < (u32)2; pass = pass + (u32)1)
            {
            Array* fl = pass == (u32)0 ? fixups : modInitFix;
            for (u32 i = (u32)0; i < fl.count(); i = i + (u32)1)
                {
                Arm64Fixup* f = (Arm64Fixup*)fl.get(i);
                if (f.symbol() == (String*)0 || f.symbol().byteLength() == (u32)0)
                    continue;
                if (symbols.get((Hashable*)f.symbol()) != (Object*)0 || commons.get((Hashable*)f.symbol()) != (Object*)0)
                    continue;
                if (!ElfArm64.inArray(undef, f.symbol()))
                    undef.add((Object*)f.symbol());
                }
            }
        ElfArm64.sortStrings(undef);
        Array* commonNames = commons.allKeys();
        ElfArm64.sortStrings(commonNames);

        Array* order = new Array();
        for (u32 i = (u32)0; i < locals.count(); i = i + (u32)1)
            order.add(locals.get(i));
        u32 firstGlobal = order.count() + (u32)1;   // after the null symbol
        for (u32 i = (u32)0; i < defText.count(); i = i + (u32)1)
            order.add(defText.get(i));
        for (u32 i = (u32)0; i < defData.count(); i = i + (u32)1)
            order.add(defData.get(i));
        for (u32 i = (u32)0; i < commonNames.count(); i = i + (u32)1)
            order.add(commonNames.get(i));
        for (u32 i = (u32)0; i < undef.count(); i = i + (u32)1)
            order.add(undef.get(i));
        Map* symIndex = new Map();
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            symIndex.set((Hashable*)(String*)order.get(i), (Object*)Number.withU32(i + (u32)1));

        bool hasInit = modInit.length() > (u32)0;
        // Section indices: 1 .text, 2 .data, then .init_array when there is one.
        u32 secInit = hasInit ? (u32)3 : (u32)0;

        Data* strtab = new Data();
        strtab.appendByte((u8)0);
        Data* symtab = new Data();
        for (u32 i = (u32)0; i < (u32)24; i = i + (u32)1)
            symtab.appendByte((u8)0);
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            String* n = (String*)order.get(i);
            ElfArm64.put32Into(symtab, strtab.length());
            for (u32 k = (u32)0; k < n.byteLength(); k = k + (u32)1)
                strtab.appendByte(n.byteAt(k));
            strtab.appendByte((u8)0);
            Array* com = (Array*)commons.get((Hashable*)n);
            if (com != (Array*)0)
                {
                // SHN_COMMON: st_value is the alignment, st_size the size.
                symtab.appendByte((u8)(((u32)1 << (u32)4) | (u32)1));   // GLOBAL OBJECT
                symtab.appendByte((u8)0);
                ElfArm64.put16Into(symtab, (u32)$FFF2);
                ElfArm64.put64Into(symtab, (u32)1 << ((Number*)com.get((u32)1)).asU32());
                ElfArm64.put64Into(symtab, ((Number*)com.get((u32)0)).asU32());
                continue;
                }
            Object* at = symbols.get((Hashable*)n);
            bool isUndef = at == (Object*)0;
            bool inData = ElfArm64.inArray(dataSyms, n);
            bool isGlobal = isUndef || exports == (Array*)0 || ElfArm64.inArray(exports, n);
            u32 type = isUndef ? (u32)0 : (inData ? (u32)1 : (u32)2);   // NOTYPE / OBJECT / FUNC
            symtab.appendByte((u8)(((isGlobal ? (u32)1 : (u32)0) << (u32)4) | type));
            symtab.appendByte((u8)0);
            ElfArm64.put16Into(symtab, isUndef ? (u32)0 : (inData ? (u32)2 : (u32)1));
            ElfArm64.put64Into(symtab, isUndef ? (u32)0 : ((Number*)at).asU32());
            ElfArm64.put64Into(symtab, (u32)0);
            }

        Data* textRel = new Data();
        Data* dataRel = new Data();
        Data* initRel = new Data();
        for (u32 pass = (u32)0; pass < (u32)2; pass = pass + (u32)1)
            {
            Array* fl = pass == (u32)0 ? fixups : modInitFix;
            for (u32 i = (u32)0; i < fl.count(); i = i + (u32)1)
                {
                Arm64Fixup* f = (Arm64Fixup*)fl.get(i);
                if (f.symbol() == (String*)0)
                    continue;
                Object* si = symIndex.get((Hashable*)f.symbol());
                if (si == (Object*)0)
                    continue;
                u32 k = f.kind();
                u32 rt = (u32)0;
                Data* into = textRel;
                if (pass == (u32)1)
                    {
                    rt = (u32)RA64_ABS64;
                    into = initRel;
                    }
                else if (k == (u32)FIXUP_BRANCH26)
                    rt = (u32)RA64_CALL26;
                else if (k == (u32)FIXUP_PAGE21)
                    rt = (u32)RA64_ADR_PREL_PG_HI21;
                else if (k == (u32)FIXUP_PAGEOFF12)
                    {
                    u32 sc = f.scale();
                    rt = sc == (u32)1 ? (u32)RA64_LDST16_ABS_LO12_NC
                       : sc == (u32)2 ? (u32)RA64_LDST32_ABS_LO12_NC
                       : sc == (u32)3 ? (u32)RA64_LDST64_ABS_LO12_NC
                       : sc == (u32)4 ? (u32)RA64_LDST128_ABS_LO12_NC
                       : (u32)RA64_ADD_ABS_LO12_NC;
                    }
                else if (k == (u32)FIXUP_GOTPAGE21)
                    rt = (u32)RA64_ADR_GOT_PAGE;
                else if (k == (u32)FIXUP_GOTPAGEOFF12)
                    rt = (u32)RA64_LD64_GOT_LO12_NC;
                else if (k == (u32)FIXUP_POINTER64)
                    {
                    rt = (u32)RA64_ABS64;
                    into = dataRel;
                    }
                else if (k == (u32)FIXUP_PREL32)
                    {
                    rt = (u32)RA64_PREL32;
                    into = dataRel;
                    }
                else if (k == (u32)FIXUP_PREL64)
                    {
                    rt = (u32)RA64_PREL64;
                    into = dataRel;
                    }
                else
                    {
                    fail(String.withFormat("an object cannot carry fixup kind %u (symbol %s)", k, f.symbol().cString()));
                    return (Data*)0;
                    }
                ElfArm64.put64Into(into, f.offset());
                ElfArm64.put32Into(into, rt);
                ElfArm64.put32Into(into, ((Number*)si).asU32());
                i32 ad = f.addend();
                ElfArm64.put32Into(into, (u32)ad);
                ElfArm64.put32Into(into, ad < (i32)0 ? (u32)$FFFFFFFF : (u32)0);
                }
            }

        Array* secNames = new Array();
        secNames.add((Object*)String.withCString(""));
        secNames.add((Object*)String.withCString(".text"));
        secNames.add((Object*)String.withCString(".data"));
        if (hasInit)
            secNames.add((Object*)String.withCString(".init_array"));
        u32 secRelText = secNames.count();
        secNames.add((Object*)String.withCString(".rela.text"));
        u32 secRelData = secNames.count();
        secNames.add((Object*)String.withCString(".rela.data"));
        u32 secRelInit = secNames.count();
        if (hasInit)
            secNames.add((Object*)String.withCString(".rela.init_array"));
        u32 secSym = secNames.count();
        secNames.add((Object*)String.withCString(".symtab"));
        u32 secStr = secNames.count();
        secNames.add((Object*)String.withCString(".strtab"));
        u32 secShstr = secNames.count();
        secNames.add((Object*)String.withCString(".shstrtab"));
        Data* shstr = new Data();
        shstr.appendByte((u8)0);
        Array* shName = new Array();
        for (u32 i = (u32)0; i < secNames.count(); i = i + (u32)1)
            {
            String* n = (String*)secNames.get(i);
            shName.add((Object*)Number.withU32(n.byteLength() == (u32)0 ? (u32)0 : shstr.length()));
            for (u32 k = (u32)0; k < n.byteLength(); k = k + (u32)1)
                shstr.appendByte(n.byteAt(k));
            if (n.byteLength() != (u32)0)
                shstr.appendByte((u8)0);
            }

        u32 textOff = (u32)64;
        u32 dataOff = ElfArm64.roundUp(textOff + text.length(), (u32)16);
        u32 initOff = ElfArm64.roundUp(dataOff + data.length(), (u32)8);
        u32 trelOff = ElfArm64.roundUp(initOff + modInit.length(), (u32)8);
        u32 drelOff = trelOff + textRel.length();
        u32 irelOff = drelOff + dataRel.length();
        u32 symOff = irelOff + initRel.length();
        u32 strOff = symOff + symtab.length();
        u32 shstrOff = strOff + strtab.length();
        u32 shOff = ElfArm64.roundUp(shstrOff + shstr.length(), (u32)8);

        p8((u32)$7F); p8((u32)'E'); p8((u32)'L'); p8((u32)'F');
        p8((u32)2); p8((u32)1); p8((u32)1);
        for (u32 i = (u32)0; i < (u32)9; i = i + (u32)1)
            p8((u32)0);
        p16((u32)1);        // ET_REL
        p16((u32)183);      // EM_AARCH64
        p32((u32)1);
        p64((u32)0);
        p64((u32)0);
        p64(shOff);
        p32((u32)0);
        p16((u32)64);
        p16((u32)0);
        p16((u32)0);
        p16((u32)64);
        p16(secNames.count());
        p16(secShstr);

        padTo(textOff);
        text.appendRangeTo(_out, (u32)0, text.length());
        padTo(dataOff);
        data.appendRangeTo(_out, (u32)0, data.length());
        if (hasInit)
            {
            padTo(initOff);
            modInit.appendRangeTo(_out, (u32)0, modInit.length());
            }
        padTo(trelOff);
        ElfArm64.appendBytes(_out, textRel);
        ElfArm64.appendBytes(_out, dataRel);
        ElfArm64.appendBytes(_out, initRel);
        ElfArm64.appendBytes(_out, symtab);
        ElfArm64.appendBytes(_out, strtab);
        ElfArm64.appendBytes(_out, shstr);
        padTo(shOff);

        // The section headers: name, type, flags, addr, offset, size, link,
        // info, addralign, entsize.
        for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1)
            p8((u32)0);
        objSection(((Number*)shName.get((u32)1)).asU32(), (u32)1, (u32)6, textOff, text.length(), (u32)0, (u32)0, (u32)16, (u32)0);
        objSection(((Number*)shName.get((u32)2)).asU32(), (u32)1, (u32)3, dataOff, data.length(), (u32)0, (u32)0, (u32)16, (u32)0);
        if (hasInit)
            objSection(((Number*)shName.get(secInit)).asU32(), (u32)14, (u32)3, initOff, modInit.length(), (u32)0, (u32)0, (u32)8, (u32)8);
        objSection(((Number*)shName.get(secRelText)).asU32(), (u32)4, (u32)$40, trelOff, textRel.length(), secSym, (u32)1, (u32)8, (u32)24);
        objSection(((Number*)shName.get(secRelData)).asU32(), (u32)4, (u32)$40, drelOff, dataRel.length(), secSym, (u32)2, (u32)8, (u32)24);
        if (hasInit)
            objSection(((Number*)shName.get(secRelInit)).asU32(), (u32)4, (u32)$40, irelOff, initRel.length(), secSym, secInit, (u32)8, (u32)24);
        objSection(((Number*)shName.get(secSym)).asU32(), (u32)2, (u32)0, symOff, symtab.length(), secStr, firstGlobal, (u32)8, (u32)24);
        objSection(((Number*)shName.get(secStr)).asU32(), (u32)3, (u32)0, strOff, strtab.length(), (u32)0, (u32)0, (u32)1, (u32)0);
        objSection(((Number*)shName.get(secShstr)).asU32(), (u32)3, (u32)0, shstrOff, shstr.length(), (u32)0, (u32)0, (u32)1, (u32)0);
        return _out;
        }

    void objSection(u32 name, u32 type, u32 flags, u32 off, u32 size, u32 link, u32 info, u32 align, u32 entsize)
        {
        p32(name);
        p32(type);
        p64(flags);
        p64((u32)0);
        p64(off);
        p64(size);
        p32(link);
        p32(info);
        p64(align);
        p64(entsize);
        }

    static void appendBytes(Data* out, Data* bytes)
        {
        out.append(bytes);
        }
    static u32 roundUp(u32 v, u32 a)
        {
        return (v + a - (u32)1) & ~(a - (u32)1);
        }
    static void put16Into(Data* b, u32 v)
        {
        b.appendByte((u8)(v & (u32)$FF));
        b.appendByte((u8)((v >> (u32)8) & (u32)$FF));
        }
    static void put32Into(Data* b, u32 v)
        {
        ElfArm64.put16Into(b, v & (u32)$FFFF);
        ElfArm64.put16Into(b, v >> (u32)16);
        }
    static void put64Into(Data* b, u32 v)
        {
        ElfArm64.put32Into(b, v);
        ElfArm64.put32Into(b, (u32)0);
        }
    static void sortStrings(Array* a)
        {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1)
            {
            Object* cur = a.get(i);
            u32 j = i;
            while (j > (u32)0 && ((String*)a.get(j - (u32)1)).compare((String*)cur) > (i32)0)
                {
                a.set(j, a.get(j - (u32)1));
                j = j - (u32)1;
                }
            a.set(j, cur);
            }
        }

    static bool inArray(Array* a, String* nm)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(nm))
                return true;
        return false;
        }

    static u32 indexIn(Array* a, String* nm)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(nm))
                return i;
        return (u32)$FFFF_FFFF;
        }

    // The SysV ELF hash DT_HASH requires — unchanged since 1995 and specified
    // byte for byte in the gABI, so it is written out rather than looked up.
    static u32 elfHash(String* name)
        {
        u32 h = (u32)0;
        for (u32 i = (u32)0; i < name.byteLength(); i = i + (u32)1)
            {
            h = (h << (u32)4) + (u32)name.byteAt(i);
            u32 g = h & (u32)$F000_0000;
            if (g != (u32)0)
                h = h ^ (g >> (u32)24);
            h = h & ~g;
            }
        return h;
        }

    // ── instruction-field patching ───────────────────────────────────────
    // AArch64 relocations do not overwrite a whole word the way x86's disp32
    // does; each splices a field into an already-encoded instruction. Read,
    // modify, write — so the register operands the assembler chose survive.
    static u32 rdw(SectionBytes* b, u32 o)
        {
        return (u32)b.byteAt(o) | ((u32)b.byteAt(o + (u32)1) << (u32)8) | ((u32)b.byteAt(o + (u32)2) << (u32)16) | ((u32)b.byteAt(o + (u32)3) << (u32)24);
        }

    static void wrw(SectionBytes* b, u32 o, u32 w)
        {
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            b.setByteAt(o + i, (u8)((w >> ((u32)8 * i)) & (u32)$FF));
        }

    // bl / b: imm26 = (target - pc) >> 2, signed, ±128 MB.
    void patchBranch26(SectionBytes* t, u32 off, u32 target, u32 site, String* sym)
        {
        i32 d = (i32)target - (i32)site;
        if ((d & (i32)3) != (i32)0)
            {
            failWith(String.withCString("unaligned branch to"), sym);
            return;
            }
        i32 imm = d >> (i32)2;
        if (imm < (i32)-33554432 || imm >= (i32)33554432)
            {
            failWith(String.withCString("out of ±128MB branch range:"), sym);
            return;
            }
        wrw(t, off, (rdw(t, off) & (u32)$FC000000) | ((u32)imm & (u32)$03FF_FFFF));
        }

    // adrp: the 21-bit page delta splits across immlo (30:29) and immhi (23:5).
    void patchAdrp(SectionBytes* t, u32 off, u32 target, u32 site, String* sym)
        {
        i32 pages = (i32)(target >> (u32)12) - (i32)(site >> (u32)12);
        if (pages < (i32)-1048576 || pages >= (i32)1048576)
            {
            failWith(String.withCString("out of adrp ±4GB range:"), sym);
            return;
            }
        u32 w = rdw(t, off) & (u32)$9F00_001F;
        wrw(t, off, w | (((u32)pages & (u32)3) << (u32)29) | ((((u32)pages >> (u32)2) & (u32)$7FFFF) << (u32)5));
        }

    // add / ldr / str immediate: imm12 at 21:10, scaled by the access size.
    // The assembler records log2(size); an unscaled offset is a hard error
    // rather than a silently truncated one.
    void patchLo12(SectionBytes* t, u32 off, u32 target, u32 scale, String* sym)
        {
        u32 lo = target & (u32)$FFF;
        if (scale != (u32)0 && (lo & (((u32)1 << scale) - (u32)1)) != (u32)0)
            {
            failWith(String.withCString("page offset is not aligned for"), sym);
            return;
            }
        u32 imm = lo >> scale;
        wrw(t, off, (rdw(t, off) & ~((u32)$FFF << (u32)10)) | ((imm & (u32)$FFF) << (u32)10));
        }

    // ── the image ────────────────────────────────────────────────────────
    //
    // `entry` non-empty makes a PIE; empty makes a shared object named by
    // `soname`. `exports` are the `.globl` names to publish, `needed` the
    // DT_NEEDED list.
    //
    // `modInitLength` is the size of the load-time constructor pointer array,
    // which the caller has appended to the TAIL of `dataIn` (8-aligned, fixups
    // shifted) with Arm64Asm.appendModInit. It becomes DT_INIT_ARRAY /
    // DT_INIT_ARRAYSZ. Zero means the program has no constructors; without the
    // tags the pointers are inert words the loader never walks (bug 124).
    void image(SectionBytes* textIn, SectionBytes* dataIn, Map* symbols, Array* dataSyms,
               Array* exportsIn, Array* fixups, String* soname, Array* needed,
               String* entry, u32 modInitLength)
        {
        image(textIn, dataIn, symbols, dataSyms, exportsIn, fixups, soname, needed,
              entry, modInitLength, (Array*)0);
        }

    // The same, with the library's serialised interface (bytes). A non-empty
    // `iface` becomes a `.xtc.iface` section after everything addressable,
    // the one the arm9 and x86_64 `.so` files carry, so `#import <Lib>` reads
    // the library's declarations out of the file (bug 460).
    void image(SectionBytes* textIn, SectionBytes* dataIn, Map* symbols, Array* dataSyms,
               Array* exportsIn, Array* fixups, String* soname, Array* needed,
               String* entry, u32 modInitLength, Array* iface)
        {
        bool isExec = entry != (String*)0 && entry.byteLength() > (u32)0;
        bool hasIface = iface != (Array*)0 && iface.count() > (u32)0;
        if (isExec && (symbols.get((Hashable*)entry) == (Object*)0 || inArray(dataSyms, entry)))
            {
            failWith(String.withCString("entry symbol is not defined in .text:"), entry);
            return;
            }

        // ── 1. imports ───────────────────────────────────────────────────
        // Anything a fixup names that this unit does not define. A `bl` import
        // is reached through a thunk; an adrp/ldr pair naming one reaches its
        // GOT slot directly. An ABSOLUTE reference to an undefined symbol
        // cannot be imported at all — that would need the referencing
        // instruction rewritten — so it is refused rather than relocated
        // against zero, which would be a null call at run time.
        Array* imports = new Array();
        Array* dataImports = new Array();
        // A `.quad` naming an import — a vtable word for another library's
        // class or method, when a library subclasses a class it imported —
        // takes an R_AARCH64_ABS64 against the symbol, which the loader fills
        // with its address. It needs a dynamic symbol but no GOT slot or
        // thunk (bug 460).
        Array* wordCand = new Array();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)fixups.get(i);
            if (symbols.get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            bool isGot = f.kind() == (u32)FIXUP_GOTPAGE21 || f.kind() == (u32)FIXUP_GOTPAGEOFF12;
            if (f.kind() == (u32)FIXUP_POINTER64)
                {
                if (!inArray(wordCand, f.symbol()))
                    wordCand.add((Object*)f.symbol());
                continue;
                }
            if (f.kind() == (u32)FIXUP_PREL32 || f.kind() == (u32)FIXUP_PREL64)
                {
                failWith(String.withCString("a PC-relative data word names an undefined symbol:"), f.symbol());
                return;
                }
            if (f.kind() != (u32)FIXUP_BRANCH26 && !isGot)
                {
                failWith(String.withCString(
                             "undefined symbol reached absolutely (a dynamic image imports "
                             "only through a GOT indirection or a call):"),
                         f.symbol());
                return;
                }
            if (isGot && !inArray(dataImports, f.symbol()))
                dataImports.add((Object*)f.symbol());
            if (!inArray(imports, f.symbol()))
                imports.add((Object*)f.symbol());
            }
        // Imports named only by data words, after the GOT imports in .dynsym.
        Array* wordImports = new Array();
        for (u32 i = (u32)0; i < wordCand.count(); i = i + (u32)1)
            if (!inArray(imports, (String*)wordCand.get(i)))
                wordImports.add(wordCand.get(i));
        // An executable's imports, checked against what its libraries define:
        // a symbol none of them has is an error here rather than at load.
        if (isExec && _known != (Map*)0)
            {
            Array* missing = new Array();
            for (u32 i = (u32)0; i < imports.count() + wordImports.count(); i = i + (u32)1)
                {
                String* n = i < imports.count() ? (String*)imports.get(i) : (String*)wordImports.get(i - imports.count());
                if (_known.get((Hashable*)n) == (Object*)0)
                    missing.add((Object*)n);
                }
            if (missing.count() > (u32)0)
                {
                missing.sort();
                String* all = new String();
                for (u32 i = (u32)0; i < missing.count(); i = i + (u32)1)
                    {
                    if (i > (u32)0) all.appendCString(", ");
                    all.append((String*)missing.get(i));
                    }
                failWith(String.withCString("undefined symbols, which no library the program links defines:"), all);
                return;
                }
            }

        // ── 2. exports ───────────────────────────────────────────────────
        Array* exports = new Array();
        for (u32 i = (u32)0; i < exportsIn.count(); i = i + (u32)1)
            {
            String* n = (String*)exportsIn.get(i);
            if (symbols.get((Hashable*)n) != (Object*)0 && !inArray(exports, n))
                exports.add((Object*)n);
            }
        // In NAME order, as the reference writer sorts them: the caller's order
        // is whatever its set iterated in, and .dynsym must not depend on that.
        exports.sort();

        // ── 3. sizes, then addresses ─────────────────────────────────────
        SectionBytes* text = textIn.copy();
        SectionBytes* data = dataIn.copy();

        u32 thunkOff = roundUpTo(text.length(), (u32)16);
        // nop padding
        while (text.length() < thunkOff)
            {
            wrwAppend(text, (u32)$D503201F);
            }

        u32 nsym = (u32)1 + exports.count() + imports.count() + wordImports.count();

        Array* symOrder = new Array();
        symOrder.add((Object*)String.withCString(""));
        for (u32 i = (u32)0; i < exports.count(); i = i + (u32)1)
            symOrder.add(exports.get(i));
        for (u32 i = (u32)0; i < imports.count(); i = i + (u32)1)
            symOrder.add(imports.get(i));
        for (u32 i = (u32)0; i < wordImports.count(); i = i + (u32)1)
            symOrder.add(wordImports.get(i));

        Data* dynstr = new Data();
        Map* strOff = new Map();
        dynstr.appendByte((u8)0); // index 0 = ""
        for (u32 i = (u32)1; i < symOrder.count(); i = i + (u32)1)
            internStr(dynstr, strOff, (String*)symOrder.get(i));
        u32 sonameOff = (u32)0;
        if (!isExec && soname != (String*)0 && soname.byteLength() > (u32)0)
            sonameOff = internStr(dynstr, strOff, soname);
        Array* neededOff = new Array();
        if (needed != (Array*)0)
            for (u32 i = (u32)0; i < needed.count(); i = i + (u32)1)
                neededOff.add((Object*)Number.withU32(
                    internStr(dynstr, strOff, (String*)needed.get(i))));
        u32 runpathOff = _runpath != (String*)0 ? internStr(dynstr, strOff, _runpath) : (u32)0;

        u32 nbucket = nsym < (u32)4 ? (u32)1 : nsym / (u32)4 + (u32)1;
        u32 hashSz = ((u32)2 + nbucket + nsym) * (u32)4;
        // The constructor array cannot be longer than the data it sits in.
        u32 miLen = modInitLength <= dataIn.length() ? modInitLength : (u32)0;
        u32 nDyn = (u32)8 + (isExec ? (u32)0 : (u32)1) + (_runpath != (String*)0 ? (u32)1 : (u32)0)
                 + neededOff.count() + (u32)1 + (miLen > (u32)0 ? (u32)2 : (u32)0);

        // One RELATIVE per `.quad <symbol>` and one GLOB_DAT per import.
        Array* absFixups = new Array();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)fixups.get(i);
            if (f.kind() == (u32)FIXUP_POINTER64)
                absFixups.add((Object*)f);
            }
        u32 nRela = absFixups.count() + imports.count();

        Array* vt = ElfArm64.vtblRun(symbols);
        u32 nphdr = (isExec ? (u32)7 : (u32)5) + (vt != (Array*)0 ? (u32)1 : (u32)0);
        u32 interpOff = roundUpTo((u32)AEHDR_SZ + nphdr * (u32)APHDR_SZ, (u32)8);
        u32 interpSz = isExec ? _interp.byteLength() + (u32)1 : (u32)0; // the path + NUL
        u32 roOff = roundUpTo(interpOff + interpSz, (u32)8);
        u32 symOff = roOff;
        u32 strOffB = symOff + nsym * (u32)ASYM_SZ;
        u32 hashOff = roundUpTo(strOffB + dynstr.length(), (u32)8);
        u32 relaOff = hashOff + hashSz;
        u32 roEnd = relaOff + nRela * (u32)ARELA_SZ;

        u32 textOff = roundUpTo(roEnd, (u32)AELF_PAGE) + (u32)AELF_PAGE;
        u32 textLen = thunkOff + imports.count() * (u32)ATHUNK_SZ;
        // .got and .dynamic precede .data in the RW segment so .data stays
        // last and its trailing zeros can be left out of the file.
        u32 rwOff = roundUpTo(textOff + textLen, (u32)AELF_PAGE) + (u32)AELF_PAGE;
        u32 gotOff = rwOff;
        u32 dynOff = gotOff + imports.count() * (u32)8;
        u32 dataAddr = roundUpTo(dynOff + nDyn * (u32)ADYN_SZ, (u32)16);
        u32 rwEnd = dataAddr + data.length();

        // ET_DYN vaddrs are file-relative: the loader picks the base and adds it.
        u32 textAddr = textOff;
        u32 thunkAddr = textOff + thunkOff;

        // ── 4. thunks ────────────────────────────────────────────────────
        // adrp x16, <got page> / ldr x17, [x16, #lo12] / br x17 — the standard
        // PLT shape minus the lazy-binding stub: every slot is bound eagerly by
        // GLOB_DAT, so there is nothing to resolve on first call.
        for (u32 i = (u32)0; i < imports.count(); i = i + (u32)1)
            {
            u32 here = thunkAddr + i * (u32)ATHUNK_SZ;
            u32 slot = gotOff + i * (u32)8;
            i32 pages = (i32)(slot >> (u32)12) - (i32)(here >> (u32)12);
            if (pages < (i32)-1048576 || pages >= (i32)1048576)
                {
                failWith(String.withCString("GOT slot out of adrp range:"),
                         (String*)imports.get(i));
                return;
                }
            wrwAppend(text, (u32)$90000010 | (((u32)pages & (u32)3) << (u32)29) | ((((u32)pages >> (u32)2) & (u32)$7FFFF) << (u32)5));
            wrwAppend(text, (u32)$F9400211 | ((((slot & (u32)$FFF) >> (u32)3) & (u32)$FFF) << (u32)10));
            wrwAppend(text, (u32)$D61F0220); // br x17
            wrwAppend(text, (u32)$D503201F); // nop (pad to 16)
            }

        // ── 5. resolve the fixups ────────────────────────────────────────
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)fixups.get(i);
            Object* off = symbols.get((Hashable*)f.symbol());
            bool isGot = f.kind() == (u32)FIXUP_GOTPAGE21 || f.kind() == (u32)FIXUP_GOTPAGEOFF12;
            u32 target;
            if (off != (Object*)0)
                target = (inArray(dataSyms, f.symbol()) ? dataAddr : textAddr) + ((Number*)off).asU32();
            else if (isGot)
                target = gotOff + indexIn(imports, f.symbol()) * (u32)8;
            else
                target = thunkAddr + indexIn(imports, f.symbol()) * (u32)ATHUNK_SZ;
            target = target + (u32)f.addend();

            if (f.kind() == (u32)FIXUP_POINTER64)
                {
                if (f.offset() + (u32)8 > data.length())
                    {
                    failWith(String.withCString("pointer64 fixup past end of data:"), f.symbol());
                    return;
                    }
                // Written with the link-time address; the RELATIVE relocation
                // makes the loader add the load bias on top. A word naming an
                // import is 0 until the loader writes S + A.
                u32 v = off != (Object*)0 ? target : (u32)0;
                for (u32 b = (u32)0; b < (u32)8; b = b + (u32)1)
                    data.setByteAt(f.offset() + b, (u8)(b < (u32)4
                                                         ? ((v >> ((u32)8 * b)) & (u32)$FF)
                                                         : (u32)0));
                continue;
                }
            if (f.kind() == (u32)FIXUP_PREL32)
                {
                // A relative word in data: settled here, no dynamic relocation.
                if (f.offset() + (u32)4 > data.length())
                    {
                    failWith(String.withCString("prel32 fixup past end of data:"), f.symbol());
                    return;
                    }
                u32 v = target - (dataAddr + f.offset());
                for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
                    data.setByteAt(f.offset() + b, (u8)((v >> ((u32)8 * b)) & (u32)$FF));
                continue;
                }
            if (f.kind() == (u32)FIXUP_PREL64)
                {
                // The same, 64 bits wide: the difference sign-extended (an
                // image is far smaller than 4 GB).
                if (f.offset() + (u32)8 > data.length())
                    {
                    failWith(String.withCString("prel64 fixup past end of data:"), f.symbol());
                    return;
                    }
                u32 v = target - (dataAddr + f.offset());
                u8 hi = (v & (u32)$80000000) != (u32)0 ? (u8)$FF : (u8)0;
                for (u32 b = (u32)0; b < (u32)8; b = b + (u32)1)
                    data.setByteAt(f.offset() + b, b < (u32)4 ? (u8)((v >> ((u32)8 * b)) & (u32)$FF) : hi);
                continue;
                }
            if (f.offset() + (u32)4 > text.length())
                {
                failWith(String.withCString("fixup past end of text:"), f.symbol());
                return;
                }
            u32 site = textAddr + f.offset();
            if (f.kind() == (u32)FIXUP_BRANCH26)
                patchBranch26(text, f.offset(), target, site, f.symbol());
            else if (f.kind() == (u32)FIXUP_PAGE21 || f.kind() == (u32)FIXUP_GOTPAGE21)
                patchAdrp(text, f.offset(), target, site, f.symbol());
            else if (f.kind() == (u32)FIXUP_PAGEOFF12)
                patchLo12(text, f.offset(), target, f.scale(), f.symbol());
            else if (f.kind() == (u32)FIXUP_GOTPAGEOFF12)
                // A GOT slot is always an 8-byte ldr, whatever the referent's size.
                patchLo12(text, f.offset(), target, (u32)3, f.symbol());
            else
                {
                failWith(String.withCString("unhandled fixup kind for"), f.symbol());
                return;
                }
            if (_failed)
                return;
            }
        u32 dataFileSz = fileSizeOf(data);
        u32 rwFileEnd = dataAddr + dataFileSz;

        // ── 6. build the file ────────────────────────────────────────────
        p8((u32)$7F);
        p8((u32)'E');
        p8((u32)'L');
        p8((u32)'F');
        p8((u32)2);
        p8((u32)1);
        p8((u32)1);
        p8((u32)0);
        p8((u32)0);
        for (u32 i = (u32)0; i < (u32)7; i = i + (u32)1)
            p8((u32)0);
        p16((u32)3);   // ET_DYN
        p16((u32)183); // EM_AARCH64
        p32((u32)1);   // e_version
        p64(isExec ? textAddr + ((Number*)symbols.get((Hashable*)entry)).asU32() : (u32)0);
        p64((u32)AEHDR_SZ); // e_phoff
        u32 shoffField = _out.length();
        p64((u32)0); // e_shoff — patched below
        p32((u32)0); // e_flags
        p16((u32)AEHDR_SZ);
        p16((u32)APHDR_SZ);
        p16(nphdr);
        p16((u32)ASHDR_SZ);
        p16(hasIface ? (u32)5 : (u32)4); // e_shnum
        p16((u32)3);                     // e_shstrndx

        if (isExec)
            {
            // Both must precede the loadable segments and both must fall
            // inside one; the first PT_LOAD starts at 0 and covers them.
            // PT_PHDR is not optional — the loader finds the executable's
            // program headers through it.
            phdr((u32)6, (u32)4, (u32)AEHDR_SZ, nphdr * (u32)APHDR_SZ, (u32)8);
            phdr((u32)3, (u32)4, interpOff, interpSz, (u32)1);
            }
        phdr((u32)1, (u32)4, (u32)0, roEnd, (u32)AELF_PAGE);    // R
        phdr((u32)1, (u32)5, textOff, textLen, (u32)AELF_PAGE); // R|X
        // By hand: the one segment whose file and memory sizes differ.
        p32((u32)1);
        p32((u32)6); // PT_LOAD, R|W
        p64(rwOff);
        p64(rwOff);
        p64(rwOff);
        p64(rwFileEnd - rwOff);
        p64(rwEnd - rwOff);
        p64((u32)AELF_PAGE);
        phdr((u32)2, (u32)6, dynOff, nDyn * (u32)ADYN_SZ, (u32)8); // PT_DYNAMIC
        // Present with no PF_X: without it the loader assumes an executable
        // stack is wanted and refuses to map the image.
        p32((u32)$6474E551);
        p32((u32)6);
        p64((u32)0);
        p64((u32)0);
        p64((u32)0);
        p64((u32)0);
        p64((u32)0);
        p64((u32)$10);
        // The class tables' run (#34), inside the RW segment.
        if (vt != (Array*)0)
            {
            u32 vlo = ((Number*)vt.get((u32)0)).asU32();
            u32 vhi = ((Number*)vt.get((u32)1)).asU32();
            phdr((u32)$60787476, (u32)4, dataAddr + vlo, vhi - vlo, (u32)8);
            }

        if (isExec)
            {
            padTo(interpOff);
            for (u32 i = (u32)0; i < _interp.byteLength(); i = i + (u32)1)
                p8((u32)_interp.byteAt(i));
            p8((u32)0);
            }
        padTo(symOff);
        for (u32 i = (u32)0; i < symOrder.count(); i = i + (u32)1)
            {
            String* n = (String*)symOrder.get(i);
            bool isNull = i == (u32)0;
            Object* off = isNull ? (Object*)0 : symbols.get((Hashable*)n);
            bool inData = off != (Object*)0 ? inArray(dataSyms, n)
                                            : (!isNull && inArray(dataImports, n));
            // An import named only by data words may be either: STT_NOTYPE.
            bool wordOnly = !isNull && off == (Object*)0 && i >= (u32)1 + exports.count() + imports.count();
            u32 stt = wordOnly ? (u32)0 : (inData ? (u32)1 : (u32)2);
            p32(isNull ? (u32)0 : lookupStr(strOff, n));
            p8(isNull ? (u32)0 : ((u32)1 << (u32)4) | stt);
            p8((u32)0);
            p16((isNull || off == (Object*)0) ? (u32)0 : (u32)1); // st_shndx
            p64(off != (Object*)0
                    ? (inData ? dataAddr : textAddr) + ((Number*)off).asU32()
                    : (u32)0);
            p64((u32)0); // st_size
            }
        padTo(strOffB);
        _out.append(dynstr);

        padTo(hashOff);
            {
            Array* bucket = new Array();
            Array* chain = new Array();
            for (u32 i = (u32)0; i < nbucket; i = i + (u32)1)
                bucket.add((Object*)Number.withU32((u32)0));
            for (u32 i = (u32)0; i < nsym; i = i + (u32)1)
                chain.add((Object*)Number.withU32((u32)0));
            for (u32 i = (u32)1; i < symOrder.count(); i = i + (u32)1)
                {
                u32 b = elfHash((String*)symOrder.get(i)) % nbucket;
                chain.set(i, bucket.get(b)); // push onto the chain
                bucket.set(b, (Object*)Number.withU32(i));
                }
            p32(nbucket);
            p32(nsym);
            for (u32 i = (u32)0; i < nbucket; i = i + (u32)1)
                p32(((Number*)bucket.get(i)).asU32());
            for (u32 i = (u32)0; i < nsym; i = i + (u32)1)
                p32(((Number*)chain.get(i)).asU32());
            }

        padTo(relaOff);
        // R_AARCH64_RELATIVE, or R_AARCH64_ABS64 against an import
        for (u32 i = (u32)0; i < absFixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)absFixups.get(i);
            Object* off = symbols.get((Hashable*)f.symbol());
            if (off == (Object*)0)
                {
                u32 wi = indexIn(imports, f.symbol());
                u32 symIdx = wi < imports.count()
                                 ? (u32)1 + exports.count() + wi
                                 : (u32)1 + exports.count() + imports.count() + indexIn(wordImports, f.symbol());
                p64(dataAddr + f.offset());
                p32((u32)257); // R_AARCH64_ABS64
                p32(symIdx);   // r_info: type | sym<<32
                p32((u32)f.addend());
                p32(f.addend() < 0 ? (u32)$FFFFFFFF : (u32)0);
                continue;
                }
            u32 target = (inArray(dataSyms, f.symbol()) ? dataAddr : textAddr) + ((Number*)off).asU32() + (u32)f.addend();
            p64(dataAddr + f.offset());
            p64((u32)1027);
            p64(target);
            }
        // R_AARCH64_GLOB_DAT
        for (u32 i = (u32)0; i < imports.count(); i = i + (u32)1)
            {
            u32 symIdx = (u32)1 + exports.count() + i;
            p64(gotOff + i * (u32)8);
            p32((u32)1025);
            p32(symIdx); // r_info: type | sym<<32
            p64((u32)0);
            }

        padTo(textOff);
        text.appendRangeTo(_out, (u32)0, text.length());
        padTo(gotOff);
        for (u32 i = (u32)0; i < imports.count(); i = i + (u32)1)
            p64((u32)0); // loader fills

        padTo(dynOff);
        for (u32 i = (u32)0; i < neededOff.count(); i = i + (u32)1)
            dyn((u32)1, ((Number*)neededOff.get(i)).asU32()); // DT_NEEDED
        // DT_SONAME names a LIBRARY; an executable claiming to be one confuses
        // the loader's lookup scope.
        if (!isExec)
            dyn((u32)14, sonameOff);
        if (_runpath != (String*)0)
            dyn((u32)29, runpathOff);       // DT_RUNPATH
        dyn((u32)4, hashOff);               // DT_HASH
        dyn((u32)5, strOffB);               // DT_STRTAB
        dyn((u32)6, symOff);                // DT_SYMTAB
        dyn((u32)10, dynstr.length());       // DT_STRSZ
        dyn((u32)11, (u32)ASYM_SZ);         // DT_SYMENT
        dyn((u32)7, relaOff);               // DT_RELA
        dyn((u32)8, nRela * (u32)ARELA_SZ); // DT_RELASZ
        dyn((u32)9, (u32)ARELA_SZ);         // DT_RELAENT
        // Bug 124. The array is the tail of .data; naming it here is the whole
        // mechanism, because bionic's loader walks DT_INIT_ARRAY before it
        // enters `_start`. The pointers already carry R_AARCH64_RELATIVE from
        // their Pointer64 fixups, so they survive a PIE's random base.
        if (miLen > (u32)0)
            {
            dyn((u32)25, dataAddr + (data.length() - miLen)); // DT_INIT_ARRAY
            dyn((u32)27, miLen);                             // DT_INIT_ARRAYSZ
            }
        dyn((u32)0, (u32)0); // DT_NULL

        padTo(dataAddr);
        data.appendRangeTo(_out, (u32)0, dataFileSz);

        // ── the section header table ─────────────────────────────────────
        // The kernel's exec path reads program headers only, so a PIE runs with
        // no section table at all. `dlopen` does NOT, and bionic's ElfReader is
        // specific about what it wants before it will map a library:
        // e_shstrndx < e_shnum (0/0 is rejected outright), a section of type
        // SHT_DYNAMIC must EXIST even though PT_DYNAMIC already says where it
        // is, its sh_offset/sh_size must equal PT_DYNAMIC's, and its sh_link
        // must name a real SHT_STRTAB. Four entries is the smallest table that
        // loads. Appended past everything addressable and outside every
        // PT_LOAD's p_filesz, so adding it moves no address.
        Data* shstr = new Data();
        Map* shOff = new Map();
        shstr.appendByte((u8)0);
        u32 nDynamic = internStr(shstr, shOff, String.withCString(".dynamic"));
        u32 nDynstr = internStr(shstr, shOff, String.withCString(".dynstr"));
        u32 nShstrtab = internStr(shstr, shOff, String.withCString(".shstrtab"));
        // A library's interface (bug 460): not loaded, so it goes after the
        // data with the other non-allocated contents and moves no address.
        u32 nIface = hasIface ? internStr(shstr, shOff, String.withCString(".xtc.iface")) : (u32)0;
        u32 ifaceOff = _out.length();
        for (u32 i = (u32)0; hasIface && i < iface.count(); i = i + (u32)1)
            p8(((Number*)iface.get(i)).asU32());
        u32 shstrOff = _out.length();
        _out.append(shstr);
        while (_out.length() % (u32)8 != (u32)0)
            p8((u32)0);
        u32 shoff = _out.length();
        shdr((u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0);
        // .dynamic — sh_link names [2], where its strings live.
        shdr(nDynamic, (u32)6, (u32)3, dynOff, dynOff, nDyn * (u32)ADYN_SZ,
             (u32)2, (u32)8, (u32)ADYN_SZ);
        shdr(nDynstr, (u32)3, (u32)2, strOffB, strOffB, dynstr.length(), (u32)0, (u32)1, (u32)0);
        shdr(nShstrtab, (u32)3, (u32)0, (u32)0, shstrOff, shstr.length(), (u32)0, (u32)1, (u32)0);
        if (hasIface)
            shdr(nIface, (u32)1, (u32)0, (u32)0, ifaceOff, iface.count(), (u32)0, (u32)1, (u32)0);

        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            _out.setByteAt(shoffField + i, (u8)(i < (u32)4
                                                 ? ((shoff >> ((u32)8 * i)) & (u32)$FF)
                                                 : (u32)0));
        }

    // ── small emitters ───────────────────────────────────────────────────
    // The class tables' run (#34): the back end puts every vtable and itable
    // of a module between `__xt_vtbl_lo` and `__xt_vtbl_hi` (a merged object's
    // labels carry its tag). The run is the span of them all, as data offsets
    // (lo, hi), or null when the image has none. It gets a program header of
    // its own (PT_XT_VTBL, in the PT_LOOS range), which a checked build's
    // vtable check reads.
    static Array* vtblRun(Map* symbols)
        {
        if (symbols == (Map*)0)
            return (Array*)0;
        String* lo = String.withCString("__xt_vtbl_lo");
        String* hi = String.withCString("__xt_vtbl_hi");
        String* loP = String.withCString("__xt_vtbl_lo$");
        String* loS = String.withCString("$__xt_vtbl_lo");
        bool any = false;
        u32 a = (u32)0;
        u32 b = (u32)0;
        Array* ks = symbols.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            {
            String* n = (String*)ks.get(i);
            String* h = (String*)0;
            if (n.equals(lo))
                h = hi;
            else if (n.hasPrefix(loP))
                {
                h = String.withString(hi);
                h.append(n.substringFromByte(lo.byteLength()));
                }
            else if (n.hasSuffix(loS))
                {
                h = n.substringBytes((u32)0, n.byteLength() - lo.byteLength());
                h.append(hi);
                }
            if (h == (String*)0)
                continue;
            Object* hv = symbols.get((Hashable*)h);
            if (hv == (Object*)0)
                continue;
            u32 x = ((Number*)symbols.get((Hashable*)n)).asU32();
            u32 y = ((Number*)hv).asU32();
            if (y <= x)
                continue;
            if (!any || x < a)
                a = x;
            if (!any || y > b)
                b = y;
            any = true;
            }
        if (!any)
            return (Array*)0;
        Array* r = new Array();
        r.add((Object*)Number.withU32(a));
        r.add((Object*)Number.withU32(b));
        return r;
        }

    void phdr(u32 type, u32 flags, u32 off, u32 sz, u32 align)
        {
        p32(type);
        p32(flags);
        p64(off);
        p64(off);
        p64(off); // vaddr == paddr == offset
        p64(sz);
        p64(sz);
        p64(align);
        }

    void dyn(u32 tag, u32 val)
        {
        p64(tag);
        p64(val);
        }

    void shdr(u32 name, u32 type, u32 flags, u32 addr, u32 off, u32 size,
              u32 link, u32 align, u32 entsize)
        {
        p32(name);
        p32(type);
        p64(flags);
        p64(addr);
        p64(off);
        p64(size);
        p32(link);
        p32((u32)0); // sh_link, sh_info
        p64(align);
        p64(entsize);
        }

    static void wrwAppend(SectionBytes* b, u32 w)
        {
        b.appendLE(w, (u32)4);
        }

    static u32 internStr(Data* blob, Map* off, String* s)
        {
        Object* have = off.get((Hashable*)s);
        if (have != (Object*)0)
            return ((Number*)have).asU32();
        u32 at = blob.length();
        off.set((Hashable*)s, (Object*)Number.withU32(at));
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            blob.appendByte(s.byteAt(i));
        blob.appendByte((u8)0);
        return at;
        }

    static u32 lookupStr(Map* off, String* s)
        {
        Object* have = off.get((Hashable*)s);
        return have == (Object*)0 ? (u32)0 : ((Number*)have).asU32();
        }
    }
