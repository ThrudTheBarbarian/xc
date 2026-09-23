// Elf64.xc — write a statically-linked x86-64 ELF executable.
// =================================================================
//
// self-hosting M21, a port of `XTElfWriter`'s static-executable path. It takes
// what the assembler produced, resolves every fixup against the final layout,
// and emits a runnable ET_EXEC — so a Mac builds a Linux binary with no Linux
// tooling anywhere in the chain.
//
// As in the Mach-O writer, addresses are kept as 32-bit FILE OFFSETS and the
// load base is added only when one is written. ELF_VBASE is 0x400000, well
// inside 32 bits, so here even the whole address fits — but the high half of
// every 64-bit field still has to be emitted, and saying so once is clearer
// than repeating a zero at forty call sites.

#import "Foundation.xc"
#import "X86Asm.xc"
#import "Files.xc" // sharedInfo reads a .so back off disk

#define ELF_PAGE $1000
#define ELF_VBASE $400000
#define EHDR_SZ 64
#define PHDR_SZ 56
#define SHDR_SZ 64
// ── ET_DYN (shared object) ───────────────────────────────────────────────
#define DT_NULL 0
#define DT_NEEDED 1
#define DT_HASH 4
#define DT_STRTAB 5
#define DT_SYMTAB 6
#define DT_RELA 7
#define DT_RELASZ 8
#define DT_RELAENT 9
#define DT_STRSZ 10
#define DT_SYMENT 11
#define DT_SONAME 14
#define DT_RUNPATH 29
#define R_X86_64_64 1
#define R_X86_64_PC32 2
#define R_X86_64_PLT32 4
#define R_X86_64_GLOB_DAT 6
#define R_X86_64_RELATIVE 8
#define STB_GLOBAL 1
#define STT_OBJECT 1
#define STT_FUNC 2
#define SYM_SZ 24
#define RELA_SZ 24
#define DYN_SZ 16
#define THUNK_SZ 6 // ff 25 <rel32> = jmp qword ptr [rip + got]
#define PT_LOAD 1
#define PT_DYNAMIC 2
#define PT_INTERP 3
#define PT_PHDR 6
#define PT_GNU_STACK $6474E551
#define PF_X 1
#define PF_W 2
#define PF_R 4
#define ET_DYN 3
#define EM_X86_64 62

// What a `.so` tells an app that wants to link against it.
class ElfSharedInfo
    {
    String* _soname;
    Array* _undefined; // String@ — what the library needs from its loader
    Array* _exported;  // String@ — what an app may bind to

    void init(void)
        {
        _soname = String.withCString("");
        _undefined = new Array();
        _exported = new Array();
        }
    String* soname(void)
        {
        return _soname;
        }
    void setSoname(String* s)
        {
        _soname = s;
        }
    Array* undefined(void)
        {
        return _undefined;
        }
    Array* exported(void)
        {
        return _exported;
        }
    }

    class Elf64
    {
    Data* _out;
    bool _failed;
    String* _why;

    void init(void)
        {
        _out = new Data();
        _failed = false;
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
        while (_out.length() < off)
            p8((u32)0);
        }

    static u32 roundUpTo(u32 v, u32 a)
        {
        return (v + a - (u32)1) & ~(a - (u32)1);
        }

    // The trailing zeros of a data section are not stored in the file — the
    // kernel zero-fills to p_memsz — so p_filesz stops at the last non-zero
    // byte.
    static u32 fileSizeOf(Data* d)
        {
        u32 n = d.length();
        while (n > (u32)0 && d.byteAt(n - (u32)1) == (u8)0)
            n = n - (u32)1;
        return n;
        }

    static u32 phdrCountFor(bool hasData)
        {
        return hasData ? (u32)3 : (u32)2;
        }

    // The headers share the first page with the code, so the text segment maps
    // from file offset 0 — p_offset and p_vaddr are then congruent modulo the
    // page size, which the kernel requires.
    static u32 textOffsetFor(u32 nphdr)
        {
        // 64, not 16. A .p2align inside .text pads relative to the START of the
        // section, so a section-relative boundary is an absolute one only when the
        // section itself is that aligned. At 16 the text base landed at 16 mod 32
        // for every program header count we emit, which put every 32-byte-aligned
        // loop head in the middle of a fetch window — measurably worse than no
        // alignment at all. 64 covers both the 32- and 64-byte fetch units, and
        // costs at most 48 bytes once per file. private:docs/bugs/232.
        return roundUpTo((u32)EHDR_SZ + nphdr * (u32)PHDR_SZ, (u32)64);
        }

    static u32 dataOffsetFor(bool hasData, u32 textLen)
        {
        return roundUpTo(textOffsetFor(phdrCountFor(hasData)) + textLen, (u32)ELF_PAGE);
        }

    // ── Fixup resolution ─────────────────────────────────────────────────
    //
    // Both section bases are known up front — the layout does not depend on the
    // fixups — so one pass resolves everything.
    // The original entry point: no ABSOLUTE symbols, which is every link that
    // uses only our own objects.
    void staticExecutable(Array* textIn, Array* dataIn, Map* symbols,
                          Array* dataSyms, Array* fixups, String* entrySymbol)
        {
        // The assembler-direct path hands Array<Number> byte lists; the linked
        // path hands Data. Convert once here (a single assembled unit is small).
        Data* t = new Data();
        for (u32 i = (u32)0; i < textIn.count(); i = i + (u32)1)
            t.appendByte((u8)((Number*)textIn.get(i)).asU32());
        Data* d = new Data();
        for (u32 i = (u32)0; i < dataIn.count(); i = i + (u32)1)
            d.appendByte((u8)((Number*)dataIn.get(i)).asU32());
        staticExecutableAbs(t, d, symbols, dataSyms, new Array(),
                            fixups, entrySymbol,
                            new Data(), new Array(), (u32)1);
        }

    // `absSyms` are names whose recorded value is the WHOLE answer rather than
    // an offset from a section base — a weak undefined that nothing in the link
    // defined, resolved to absolute 0. They only arise when foreign objects are
    // merged (task #47), which is also where the GOT and TLS kinds below come
    // from; nothing this assembler emits needs any of it.
    void staticExecutableAbs(Data* textIn, Data* dataIn, Map* symbols,
                             Array* dataSyms, Array* absSyms,
                             Array* fixups, String* entrySymbol,
                             Data* bss, Array* bssSyms, u32 bssAlign)
        {
        Map* dataSet = Elf64.setOf(dataSyms);
        Map* absSet = Elf64.setOf(absSyms);
        Object* entry = symbols.get((Hashable*)entrySymbol);
        if (entry == (Object*)0 || Elf64.inSet(dataSet, entrySymbol))
            {
            failWith(String.withCString("entry symbol is not defined in the text section"),
                     entrySymbol);
            return;
            }
        Data* text = Data.withData(textIn);
        Data* data = Data.withData(dataIn);

        // ── link-time GOT ──
        // A GOTPCREL (type 9) reads its slot's 8 bytes AS DATA, so the mov→lea
        // relaxation cannot apply; it needs a real slot. A GOTPCRELX whose
        // opcode is not the relaxable `mov` (0x8b) takes one too, rather than
        // being an error. Slots are 8 bytes at the end of DATA in FIRST-SEEN
        // order — that order IS the layout, so it must not depend on hash
        // iteration.
        Map* gotSlot = new Map();
        Array* gotOrder = new Array();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)fixups.get(i);
            bool wants = f.kind() == (u32)X86FIX_GOTREF;
            if (f.kind() == (u32)X86FIX_GOTLOAD)
                {
                if (f.offset() < (u32)2 || f.offset() > text.length())
                    wants = true;
                else if ((u32)text.byteAt(f.offset() - (u32)2) != (u32)$8B)
                    wants = true;
                }
            if (!wants)
                continue;
            if (gotSlot.get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            gotSlot.set((Hashable*)f.symbol(), (Object*)Number.withU32((u32)0));
            gotOrder.add((Object*)f.symbol());
            }
        if (gotOrder.count() > (u32)0)
            {
            while (data.length() % (u32)8 != (u32)0)
                data.appendByte((u8)((u32)0));
            for (u32 i = (u32)0; i < gotOrder.count(); i = i + (u32)1)
                {
                gotSlot.set((Hashable*)gotOrder.get(i), (Object*)Number.withU32(data.length()));
                for (u32 k = (u32)0; k < (u32)8; k = k + (u32)1)
                    data.appendByte((u8)((u32)0));
                }
            }

        // Fold COMMON (NOBITS) storage onto the END of data, AFTER the GOT, so
        // its trailing zeros stay trailing and fileSizeOf keeps them out of
        // p_filesz (they cost memory, not file size). The bss syms were
        // classified as data syms; rebase them from bss-relative to
        // data-relative now, before any fixup reads their address.
        if (bss.length() > (u32)0)
            {
            u32 bal = bssAlign < (u32)8 ? (u32)8 : bssAlign;
            while (data.length() % bal != (u32)0)
                data.appendByte((u8)((u32)0));
            u32 bbase = data.length();
            for (u32 bi = (u32)0; bi < bssSyms.count(); bi = bi + (u32)1)
                {
                String* bnm = (String*)bssSyms.get(bi);
                Object* bo = symbols.get((Hashable*)bnm);
                if (bo != (Object*)0)
                    symbols.set((Hashable*)bnm, (Object*)Number.withU32(bbase + ((Number*)bo).asU32()));
                }
            data.append(bss);
            }

        bool hasData = data.length() > (u32)0;
        u32 textAddr = (u32)ELF_VBASE + textOffsetFor(phdrCountFor(hasData));
        u32 dataAddr = (u32)ELF_VBASE + dataOffsetFor(hasData, text.length()) + (u32)ELF_PAGE;

        // TPOFF32 first and on its own: the addend already IS the final
        // %fs-relative offset (the caller resolved it once the thread block's
        // size was known), so there is no symbol to look up at all.
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)fixups.get(i);
            if (f.kind() != (u32)X86FIX_TPOFF32)
                continue;
            if (f.offset() + (u32)4 > text.length())
                {
                failWith(String.withCString("tpoff fixup past the end of text"), f.symbol());
                return;
                }
            for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                text.setByteAt(f.offset() + k,
                               (u8)(((u32)f.addend() >> ((u32)8 * k)) & (u32)$FF));
            }

        // Fill each GOT slot with its symbol's absolute address. A static,
        // non-PIE image needs no runtime relocation to do it.
        for (u32 i = (u32)0; i < gotOrder.count(); i = i + (u32)1)
            {
            String* sym = (String*)gotOrder.get(i);
            Object* off = symbols.get((Hashable*)sym);
            if (off == (Object*)0)
                {
                failWith(String.withCString("undefined symbol (a static link resolves everything in-house — is the runtime missing?)"),
                         sym);
                return;
                }
            u32 v = Elf64.inSet(absSet, sym) ? ((Number*)off).asU32()
                                             : (Elf64.inSet(dataSet, sym) ? dataAddr : textAddr) + ((Number*)off).asU32();
            u32 so = ((Number*)gotSlot.get((Hashable*)sym)).asU32();
            for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                data.setByteAt(so + k, (u8)((v >> ((u32)8 * k)) & (u32)$FF));
            for (u32 k = (u32)4; k < (u32)8; k = k + (u32)1)
                data.setByteAt(so + k, (u8)((u32)0));
            }

        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)fixups.get(i);
            if (f.kind() == (u32)X86FIX_TPOFF32)
                continue; // patched above
            Object* off = symbols.get((Hashable*)f.symbol());
            if (off == (Object*)0)
                {
                failWith(String.withCString("undefined symbol (a static link resolves everything in-house — is the runtime missing?)"),
                         f.symbol());
                return;
                }
            bool inData = Elf64.inSet(dataSet, f.symbol());
            // An ABSOLUTE symbol's recorded value is the whole answer — it is
            // not an offset from any section.
            u32 target = Elf64.inSet(absSet, f.symbol())
                             ? ((Number*)off).asU32()
                             : (inData ? dataAddr : textAddr) + ((Number*)off).asU32();
            // a PC-relative slot in DATA
            if (f.kind() == (u32)X86FIX_PC32DATA)
                {
                if (f.offset() + (u32)4 > data.length())
                    {
                    failWith(String.withCString("pc32 fixup past the end of data"), f.symbol());
                    return;
                    }
                i32 drel = (i32)target - (i32)(dataAddr + f.offset()) + f.addend();
                for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                    data.setByteAt(f.offset() + k,
                                   (u8)(((u32)drel >> ((u32)8 * k)) & (u32)$FF));
                continue;
                }
            // .quad <symbol>, in data
            if (f.kind() == (u32)X86FIX_ABS64)
                {
                if (f.offset() + (u32)8 > data.length())
                    {
                    failWith(String.withCString("abs64 fixup past the end of data"), f.symbol());
                    return;
                    }
                u32 v = target + (u32)f.addend();
                for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                    data.setByteAt(f.offset() + k, (u8)((v >> ((u32)8 * k)) & (u32)$FF));
                for (u32 k = (u32)4; k < (u32)8; k = k + (u32)1)
                    data.setByteAt(f.offset() + k, (u8)((u32)0));
                continue;
                }
            // Rel32 and PC32, both in text and both measured from the field.
            if (f.offset() + (u32)4 > text.length())
                {
                failWith(String.withCString("pc32 fixup past the end of text"), f.symbol());
                return;
                }
            // A RELAXABLE GOT load — the opcode two bytes back is `mov` —
            // becomes `lea` and takes S + A - P directly, with no slot at all.
            // Anything else that named the GOT resolves against its slot
            // instead, so the field takes G + A - P.
            if (f.kind() == (u32)X86FIX_GOTLOAD && f.offset() >= (u32)2 && (u32)text.byteAt(f.offset() - (u32)2) == (u32)$8B)
                {
                text.setByteAt(f.offset() - (u32)2, (u8)((u32)$8D));
                }
            else if (f.kind() == (u32)X86FIX_GOTLOAD || f.kind() == (u32)X86FIX_GOTREF)
                {
                Object* g = gotSlot.get((Hashable*)f.symbol());
                // unreachable by construction — refuse, don't mis-patch
                if (g == (Object*)0)
                    {
                    failWith(String.withCString("no GOT slot allocated for"), f.symbol());
                    return;
                    }
                target = dataAddr + ((Number*)g).asU32();
                }
            i32 rel = (i32)target - (i32)(textAddr + f.offset()) + f.addend();
            for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                text.setByteAt(f.offset() + k, (u8)(((u32)rel >> ((u32)8 * k)) & (u32)$FF));
            }
        emitExec(text, data, symbols, dataSyms, ((Number*)entry).asU32());
        }

    static Array* copyBytes(Array* a)
        {
        Array* o = new Array();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            o.add(a.get(i));
        return o;
        }

    // ── Reading a shared object back ─────────────────────────────────────
    //
    // What an app needs to link against a `.so`: its SONAME (which becomes a
    // DT_NEEDED) and the names it leaves UNDEFINED (which the app must then
    // provide, because a single-libc image is the provider — see
    // docs/bugs/x86_64 cross-.so notes).
    //
    // Read through the SECTION headers. ld.so itself reads program headers, but
    // our own writer emits sections for exactly this kind of reader, and a
    // stripped `.so` with none is not something this toolchain produces.
    //
    // Returns null when the file is not an ET_DYN x86-64 ELF, so the caller can
    // say which of the two it was rather than guessing.
    static ElfSharedInfo* sharedInfo(String* path)
        {
        Data* d = Files.readData(path);
        if (d == (Data*)0 || d.length() < (u32)EHDR_SZ)
            return (ElfSharedInfo*)0;
        if (d.byteAt((u32)0) != (u8)$7F || d.byteAt((u32)1) != (u8)'E' || d.byteAt((u32)2) != (u8)'L' || d.byteAt((u32)3) != (u8)'F')
            return (ElfSharedInfo*)0;
        if (d.byteAt((u32)4) != (u8)2 || d.byteAt((u32)5) != (u8)1)
            return (ElfSharedInfo*)0;
        if (Elf64.rd16(d, (u32)16) != (u32)ET_DYN)
            return (ElfSharedInfo*)0;

        u32 shoff = Elf64.rd32(d, (u32)40); // 64-bit, but our images are < 4 GB
        u32 shentsize = Elf64.rd16(d, (u32)58);
        u32 shnum = Elf64.rd16(d, (u32)60);
        if (shnum == (u32)0 || shoff + shnum * shentsize > d.length())
            return (ElfSharedInfo*)0;
        u32 dynsymOff = (u32)0;
        u32 dynsymSz = (u32)0;
        u32 dynsymLink = (u32)0;
        u32 dynOff = (u32)0;
        u32 dynSz = (u32)0;
        for (u32 i = (u32)0; i < shnum; i = i + (u32)1)
            {
            u32 sh = shoff + i * shentsize;
            u32 type = Elf64.rd32(d, sh + (u32)4);
            // SHT_DYNSYM
            if (type == (u32)11)
                {
                dynsymOff = Elf64.rd32(d, sh + (u32)24);
                dynsymSz = Elf64.rd32(d, sh + (u32)32);
                dynsymLink = Elf64.rd32(d, sh + (u32)40);
                }
            // SHT_DYNAMIC
            else if (type == (u32)6)
                {
                dynOff = Elf64.rd32(d, sh + (u32)24);
                dynSz = Elf64.rd32(d, sh + (u32)32);
                }
            }
        if (dynsymOff == (u32)0 || dynsymLink >= shnum)
            return (ElfSharedInfo*)0;
        u32 ls = shoff + dynsymLink * shentsize;
        u32 strOff = Elf64.rd32(d, ls + (u32)24);
        u32 strSz = Elf64.rd32(d, ls + (u32)32);

        ElfSharedInfo* info = new ElfSharedInfo();
        // Every GLOBAL or WEAK symbol with SHN_UNDEF: what the library needs
        // from whoever loads it.
        for (u32 o = dynsymOff; o + (u32)24 <= dynsymOff + dynsymSz && o + (u32)24 <= d.length(); o = o + (u32)24)
            {
            u32 stName = Elf64.rd32(d, o);
            u32 bind = ((u32)d.byteAt(o + (u32)4)) >> (u32)4;
            u32 shndx = Elf64.rd16(d, o + (u32)6);
            if (shndx != (u32)0 || stName == (u32)0)
                continue;
            if (bind != (u32)1 && bind != (u32)2)
                continue; // GLOBAL / WEAK
            String* n = Elf64.strAt(d, strOff, strSz, stName);
            if (n.byteLength() > (u32)0)
                info.undefined().add((Object*)n);
            continue;
            }
        // …and every DEFINED global, which is what an app links AGAINST.
        for (u32 o = dynsymOff; o + (u32)24 <= dynsymOff + dynsymSz && o + (u32)24 <= d.length(); o = o + (u32)24)
            {
            u32 stName = Elf64.rd32(d, o);
            u32 bind = ((u32)d.byteAt(o + (u32)4)) >> (u32)4;
            u32 shndx = Elf64.rd16(d, o + (u32)6);
            if (shndx == (u32)0 || stName == (u32)0)
                continue;
            if (bind != (u32)1 && bind != (u32)2)
                continue;
            String* n = Elf64.strAt(d, strOff, strSz, stName);
            if (n.byteLength() > (u32)0)
                info.exported().add((Object*)n);
            }
        info.setSoname(path.lastPathComponent());
        for (u32 o = dynOff; dynOff != (u32)0 && o + (u32)16 <= dynOff + dynSz && o + (u32)16 <= d.length(); o = o + (u32)16)
            {
            u32 tag = Elf64.rd32(d, o);
            u32 val = Elf64.rd32(d, o + (u32)8);
            if (tag == (u32)DT_NULL)
                break;
            if (tag == (u32)DT_SONAME)
                {
                String* n = Elf64.strAt(d, strOff, strSz, val);
                if (n.byteLength() > (u32)0)
                    info.setSoname(n);
                }
            }
        return info;
        }

    static u32 rd16(Data* d, u32 at)
        {
        return (u32)d.byteAt(at) | ((u32)d.byteAt(at + (u32)1) << (u32)8);
        }

    static u32 rd32(Data* d, u32 at)
        {
        return (u32)d.byteAt(at) | ((u32)d.byteAt(at + (u32)1) << (u32)8) | ((u32)d.byteAt(at + (u32)2) << (u32)16) | ((u32)d.byteAt(at + (u32)3) << (u32)24);
        }

    static String* strAt(Data* d, u32 base, u32 size, u32 off)
        {
        String* out = new String();
        if (off >= size)
            return out;
        u32 i = base + off;
        while (i < d.length() && i < base + size && d.byteAt(i) != (u8)0)
            {
            out.appendByte(d.byteAt(i));
            i = i + (u32)1;
            }
        return out;
        }

    // ── The SHARED OBJECT (ET_DYN) ───────────────────────────────────────
    //
    // The Linux analogue of MachO.dylib: `soname` names the library, `exports`
    // are the `.globl` names it publishes, `needed` its DT_NEEDEDs, `iface` the
    // serialised module interface that rides in a `.xtc.iface` section so
    // `#import <Lib>` can read the types out of the binary.
    //
    // `entry` non-empty makes a dynamically-linked EXECUTABLE instead — the
    // same file plus PT_PHDR, PT_INTERP and an e_entry, because ld.so processes
    // exactly the PT_DYNAMIC either way.
    // `absSyms` are names whose recorded value is the WHOLE answer rather than
    // an offset from a section base — the linker-synthesised init/fini array
    // bounds, and weak undefineds that resolved to absolute zero. They only
    // arise on the dynamic-EXECUTABLE path, where foreign objects are merged;
    // a library link passes none and the output is unchanged.
    void sharedObject(Data* textIn, Data* dataIn, Map* symbols, Array* dataSyms,
                      Array* exportsIn, Array* fixups, String* soname,
                      Array* needed, String* entry, String* runpath, Array* iface,
                      Array* absSyms, Data* bss, Array* bssSyms, u32 bssAlign)
        {
        // O(1) membership sets for the per-fixup / per-symbol loops below
        // (were O(n^2) linear scans of dataSyms/absSyms per fixup).
        Map* dataSet = Elf64.setOf(dataSyms);
        Map* absSet = Elf64.setOf(absSyms);
        bool isExec = entry != (String*)0 && entry.byteLength() > (u32)0;
        if (isExec && (symbols.get((Hashable*)entry) == (Object*)0 || Elf64.inSet(dataSet, entry)))
            {
            failWith(String.withCString("entry symbol is not defined in .text:"), entry);
            return;
            }
        bool hasIface = iface != (Array*)0 && iface.count() > (u32)0;

        // ── 1. imports ───────────────────────────────────────────────────
        // A call (Rel32) import is reached through a thunk; a GOT-loaded DATA
        // import through a slot the loader fills. Anything else undefined
        // cannot be imported at all — the referencing instruction would have to
        // be rewritten — so it is refused rather than relocated against zero,
        // which would be a null call at run time.
        Array* imports = new Array();
        Array* dataImports = new Array();
        Map* importsSet = new Map();
        Map* dataImportsSet = new Map();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)fixups.get(i);
            if (symbols.get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            bool isGot = f.kind() == (u32)X86FIX_GOTLOAD || f.kind() == (u32)X86FIX_GOTREF;
            if (f.kind() != (u32)X86FIX_REL32 && !isGot)
                {
                failWith(String.withCString(
                             "undefined symbol reached without a GOT load (a shared object "
                             "imports only through a GOT indirection or a call):"),
                         f.symbol());
                return;
                }
            if (isGot && !Elf64.inSet(dataImportsSet, f.symbol()))
                {
                dataImports.add((Object*)f.symbol());
                dataImportsSet.set((Hashable*)f.symbol(), (Object*)Number.withU32((u32)1));
                }
            if (!Elf64.inSet(importsSet, f.symbol()))
                {
                imports.add((Object*)f.symbol());
                importsSet.set((Hashable*)f.symbol(), (Object*)Number.withU32((u32)1));
                }
            }

        // ── 2. exports ───────────────────────────────────────────────────
        // SORTED, not in `.globl` order: the symbol table's order is part of
        // the file, and leaving it to the order the assembler happened to see
        // the directives would make the output depend on the source's layout.
        Array* exports = new Array();
        Map* exportsSet = new Map();
        for (u32 i = (u32)0; exportsIn != (Array*)0 && i < exportsIn.count(); i = i + (u32)1)
            {
            String* n = (String*)exportsIn.get(i);
            if (symbols.get((Hashable*)n) != (Object*)0 && !Elf64.inSet(exportsSet, n))
                {
                exports.add((Object*)n);
                exportsSet.set((Hashable*)n, (Object*)Number.withU32((u32)1));
                }
            }
        Elf64.sortStrings(exports);

        // ── 3. sizes, then addresses ─────────────────────────────────────
        Data* text = Data.withData(textIn);
        Data* data = Data.withData(dataIn);

        // Fold COMMON (NOBITS) storage onto the END of data. Here .got/.dynamic
        // precede .data in the RW segment, so .data stays last and its trailing
        // bss zeros are trimmed from p_filesz by fileSizeOf below. Rebase the bss
        // syms (classified as data syms) from bss-relative to data-relative.
        if (bss.length() > (u32)0)
            {
            u32 bal = bssAlign < (u32)8 ? (u32)8 : bssAlign;
            while (data.length() % bal != (u32)0)
                data.appendByte((u8)((u32)0));
            u32 bbase = data.length();
            for (u32 bi = (u32)0; bi < bssSyms.count(); bi = bi + (u32)1)
                {
                String* bnm = (String*)bssSyms.get(bi);
                Object* bo = symbols.get((Hashable*)bnm);
                if (bo != (Object*)0)
                    symbols.set((Hashable*)bnm, (Object*)Number.withU32(bbase + ((Number*)bo).asU32()));
                }
            data.append(bss);
            }

        // A GOT reference to an ABSOLUTE symbol — a linker-synthesised init/fini
        // bound, or a weak undefined resolved to zero — cannot be relaxed to
        // `lea`: lea computes a PC-relative ADDRESS, and the point of an
        // absolute symbol is that its value IS the answer. Each gets a real GOT
        // slot holding that value, with no relocation, because there is no load
        // bias to add to it. Only the dynamic-executable path produces any.
        Array* absGot = new Array();
        Map* absGotSet = new Map();
        for (u32 i = (u32)0; absSyms != (Array*)0 && i < fixups.count(); i = i + (u32)1)
            {
            X86Fixup* fx = (X86Fixup*)fixups.get(i);
            if (fx.kind() != (u32)X86FIX_GOTLOAD && fx.kind() != (u32)X86FIX_GOTREF)
                continue;
            if (symbols.get((Hashable*)fx.symbol()) == (Object*)0)
                continue;
            if (!Elf64.inSet(absSet, fx.symbol()))
                continue;
            if (!Elf64.inSet(absGotSet, fx.symbol()))
                {
                absGot.add((Object*)fx.symbol());
                absGotSet.set((Hashable*)fx.symbol(), (Object*)Number.withU32((u32)1));
                }
            }
        u32 ngot = imports.count() + absGot.count();

        u32 thunkOff = text.length(); // thunks are appended to .text
        u32 nsym = (u32)1 + exports.count() + imports.count();

        Array* symOrder = new Array();
        symOrder.add((Object*)String.withCString(""));
        for (u32 i = (u32)0; i < exports.count(); i = i + (u32)1)
            symOrder.add(exports.get(i));
        for (u32 i = (u32)0; i < imports.count(); i = i + (u32)1)
            symOrder.add(imports.get(i));

        Array* dynstr = new Array();
        Map* strOff = new Map();
        dynstr.add((Object*)Number.withU32((u32)0)); // index 0 = ""
        for (u32 i = (u32)1; i < symOrder.count(); i = i + (u32)1)
            Elf64.internStr(dynstr, strOff, (String*)symOrder.get(i));
        u32 sonameOff = (u32)0;
        if (soname != (String*)0 && soname.byteLength() > (u32)0)
            sonameOff = Elf64.internStr(dynstr, strOff, soname);
        Array* neededOff = new Array();
        if (needed != (Array*)0)
            for (u32 i = (u32)0; i < needed.count(); i = i + (u32)1)
                neededOff.add((Object*)Number.withU32(
                    Elf64.internStr(dynstr, strOff, (String*)needed.get(i))));
        bool hasRunpath = runpath != (String*)0 && runpath.byteLength() > (u32)0;
        u32 runpathOff = hasRunpath ? Elf64.internStr(dynstr, strOff, runpath) : (u32)0;

        u32 nbucket = nsym < (u32)4 ? (u32)1 : nsym / (u32)4 + (u32)1;
        u32 hashSz = ((u32)2 + nbucket + nsym) * (u32)4;
        u32 nDyn = (u32)8 + (isExec ? (u32)0 : (u32)1) + (hasRunpath ? (u32)1 : (u32)0) + neededOff.count() + (u32)1;

        // Only an ABS64 needs a dynamic relocation. A PC32Data slot — a jump
        // table's `.long target - base` — is a difference of two in-image
        // addresses, invariant under the load bias, so it is resolved here and
        // gets none. (Lumping it in emitted an 8-byte RELATIVE over a 4-byte
        // slot and left the table zero.)
        Array* absFixups = new Array();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)fixups.get(i);
            if (f.kind() == (u32)X86FIX_ABS64)
                absFixups.add((Object*)f);
            }
        u32 nRela = absFixups.count() + imports.count();

        u32 nphdr = isExec ? (u32)7 : (u32)5;
        u32 interpOff = roundUpTo((u32)EHDR_SZ + nphdr * (u32)PHDR_SZ, (u32)8);
        u32 interpSz = isExec ? (u32)28 : (u32)0; // "/lib64/ld-linux-x86-64.so.2" + NUL
        u32 roOff = roundUpTo(interpOff + interpSz, (u32)8);
        u32 symOffB = roOff;
        u32 strOffB = symOffB + nsym * (u32)SYM_SZ;
        u32 hashOff = roundUpTo(strOffB + dynstr.count(), (u32)8);
        u32 relaOff = hashOff + hashSz;
        u32 roEnd = relaOff + nRela * (u32)RELA_SZ;

        u32 textOff = roundUpTo(roEnd, (u32)ELF_PAGE) + (u32)ELF_PAGE;
        u32 textLen = text.length() + imports.count() * (u32)THUNK_SZ;
        // .got and .dynamic precede .data in the RW segment so .data stays last
        // and its trailing zeros can be left out of the file.
        u32 rwOff = roundUpTo(textOff + textLen, (u32)ELF_PAGE) + (u32)ELF_PAGE;
        u32 gotOff = rwOff;
        u32 dynOff = gotOff + ngot * (u32)8;
        u32 dataAddr = roundUpTo(dynOff + nDyn * (u32)DYN_SZ, (u32)16);
        u32 rwEnd = dataAddr + data.length();

        u32 textAddr = textOff; // ET_DYN vaddr == file offset
        u32 thunkAddr = textOff + thunkOff;

        // ── 4. thunks: jmp qword ptr [rip + <got slot>] ──────────────────
        for (u32 i = (u32)0; i < imports.count(); i = i + (u32)1)
            {
            u32 here = thunkAddr + i * (u32)THUNK_SZ;
            i32 rel = (i32)(gotOff + i * (u32)8) - (i32)(here + (u32)THUNK_SZ);
            text.appendByte((u8)((u32)$FF));
            text.appendByte((u8)((u32)$25));
            for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
                text.appendByte((u8)(((u32)rel >> ((u32)8 * b)) & (u32)$FF));
            }

        // ── 5. resolve the fixups ────────────────────────────────────────
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)fixups.get(i);
            Object* off = symbols.get((Hashable*)f.symbol());
            bool isGot = f.kind() == (u32)X86FIX_GOTLOAD || f.kind() == (u32)X86FIX_GOTREF;
            u32 target;
            if (off != (Object*)0)
                target = (absSyms != (Array*)0 && Elf64.inSet(absSet, f.symbol()))
                             ? ((Number*)off).asU32()
                             : (Elf64.inSet(dataSet, f.symbol()) ? dataAddr : textAddr) + ((Number*)off).asU32();
            else if (isGot)
                target = gotOff + Elf64.indexIn(imports, f.symbol()) * (u32)8;
            else
                target = thunkAddr + Elf64.indexIn(imports, f.symbol()) * (u32)THUNK_SZ;

            if (f.kind() == (u32)X86FIX_ABS64)
                {
                if (f.offset() + (u32)8 > data.length())
                    {
                    failWith(String.withCString("abs64 fixup past end of data:"), f.symbol());
                    return;
                    }
                u32 v = target + (u32)f.addend();
                for (u32 b = (u32)0; b < (u32)8; b = b + (u32)1)
                    data.setByteAt(f.offset() + b, (u8)(b < (u32)4 ? ((v >> ((u32)8 * b)) & (u32)$FF) : (u32)0));
                continue;
                }
            if (f.kind() == (u32)X86FIX_PC32DATA)
                {
                if (f.offset() + (u32)4 > data.length())
                    {
                    failWith(String.withCString("pc32 fixup past end of data:"), f.symbol());
                    return;
                    }
                i32 drel = (i32)target - (i32)(dataAddr + f.offset()) + f.addend();
                for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
                    data.setByteAt(f.offset() + b,
                                   (u8)(((u32)drel >> ((u32)8 * b)) & (u32)$FF));
                continue;
                }
            if (f.offset() + (u32)4 > text.length())
                {
                failWith(String.withCString("fixup past end of text:"), f.symbol());
                return;
                }
            // A GOTPCRELX to a symbol we DEFINE has no GOT slot: relax mov→lea
            // and resolve directly. One to an IMPORT keeps the load, because
            // its displacement must point at the loader-filled slot.
            bool isAbsSym = off != (Object*)0 && absSyms != (Array*)0 && Elf64.inSet(absSet, f.symbol());
            if (isGot && isAbsSym)
                {
                target = gotOff + (imports.count() + Elf64.indexIn(absGot, f.symbol())) * (u32)8;
                }
            else if (f.kind() == (u32)X86FIX_GOTLOAD && off != (Object*)0)
                {
                if (f.offset() < (u32)2 || (u32)text.byteAt(f.offset() - (u32)2) != (u32)$8B)
                    {
                    failWith(String.withCString(
                                 "GOTPCRELX is not a relaxable mov (only mov->lea is implemented):"),
                             f.symbol());
                    return;
                    }
                text.setByteAt(f.offset() - (u32)2, (u8)((u32)$8D));
                }
            i32 rel = (i32)target - (i32)(textAddr + f.offset()) + f.addend();
            for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
                text.setByteAt(f.offset() + b,
                               (u8)(((u32)rel >> ((u32)8 * b)) & (u32)$FF));
            }
        u32 dataFileSz = fileSizeOf(data);
        u32 rwFileEnd = dataAddr + dataFileSz;

        // ── 6. the file ──────────────────────────────────────────────────
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
        p16((u32)ET_DYN);
        p16((u32)EM_X86_64);
        p32((u32)1);
        u32 entryField = _out.length();
        p64((u32)0); // e_entry — patched below
        p64((u32)EHDR_SZ);
        u32 shoffField = _out.length();
        p64((u32)0); // e_shoff — patched below
        p32((u32)0);
        p16((u32)EHDR_SZ);
        p16((u32)PHDR_SZ);
        p16(nphdr);
        p16((u32)SHDR_SZ);
        u32 shnumField = _out.length();
        p16((u32)0);
        p16((u32)0); // e_shnum / e_shstrndx — patched

        if (isExec)
            {
            phdr((u32)PT_PHDR, (u32)PF_R, (u32)EHDR_SZ, nphdr * (u32)PHDR_SZ, (u32)8);
            phdr((u32)PT_INTERP, (u32)PF_R, interpOff, interpSz, (u32)1);
            }
        phdr((u32)PT_LOAD, (u32)PF_R, (u32)0, roEnd, (u32)ELF_PAGE);
        phdr((u32)PT_LOAD, (u32)PF_R | (u32)PF_X, textOff, textLen, (u32)ELF_PAGE);
        // By hand: the one segment whose file and memory sizes differ.
        p32((u32)PT_LOAD);
        p32((u32)PF_R | (u32)PF_W);
        p64(rwOff);
        p64(rwOff);
        p64(rwOff);
        p64(rwFileEnd - rwOff);
        p64(rwEnd - rwOff);
        p64((u32)ELF_PAGE);
        phdr((u32)PT_DYNAMIC, (u32)PF_R | (u32)PF_W, dynOff, nDyn * (u32)DYN_SZ, (u32)8);
        // Present with no PF_X: without it the loader assumes an executable
        // stack is wanted and refuses to map the image.
        p32((u32)PT_GNU_STACK);
        p32((u32)PF_R | (u32)PF_W);
        p64((u32)0);
        p64((u32)0);
        p64((u32)0);
        p64((u32)0);
        p64((u32)0);
        p64((u32)$10);

        if (isExec)
            {
            padTo(interpOff);
            String* it = String.withCString("/lib64/ld-linux-x86-64.so.2");
            for (u32 i = (u32)0; i < it.byteLength(); i = i + (u32)1)
                p8((u32)it.byteAt(i));
            p8((u32)0);
            }
        padTo(symOffB);
        for (u32 i = (u32)0; i < symOrder.count(); i = i + (u32)1)
            {
            String* n = (String*)symOrder.get(i);
            bool isNull = i == (u32)0;
            Object* off = isNull ? (Object*)0 : symbols.get((Hashable*)n);
            // A defined data symbol, or an undefined DATA import, is
            // STT_OBJECT; everything else a function. Advisory for GLOB_DAT,
            // but it keeps `nm` and the loader's diagnostics honest.
            bool inData = off != (Object*)0 ? Elf64.inSet(dataSet, n)
                                            : (!isNull && Elf64.inSet(dataImportsSet, n));
            p32(isNull ? (u32)0 : Elf64.lookupStr(strOff, n));
            p8(isNull ? (u32)0 : (((u32)STB_GLOBAL << (u32)4) | (inData ? (u32)STT_OBJECT : (u32)STT_FUNC)));
            p8((u32)0);
            bool isAbs = off != (Object*)0 && Elf64.inSet(absSet, n);
            // SHN_ABS: the value is the answer, and the loader must not add a
            // section base to it.
            p16(isNull || off == (Object*)0 ? (u32)0
                                            : (isAbs ? (u32)$FFF1 : (u32)1));
            p64(off == (Object*)0 ? (u32)0
                                  : (isAbs ? ((Number*)off).asU32()
                                           : (inData ? dataAddr : textAddr) + ((Number*)off).asU32()));
            p64((u32)0);
            }
        padTo(strOffB);
        for (u32 i = (u32)0; i < dynstr.count(); i = i + (u32)1)
            p8(((Number*)dynstr.get(i)).asU32());

        padTo(hashOff);
        Array* bucket = new Array();
        Array* chain = new Array();
        for (u32 i = (u32)0; i < nbucket; i = i + (u32)1)
            bucket.add((Object*)Number.withU32((u32)0));
        for (u32 i = (u32)0; i < nsym; i = i + (u32)1)
            chain.add((Object*)Number.withU32((u32)0));
        for (u32 i = (u32)1; i < symOrder.count(); i = i + (u32)1)
            {
            u32 b = Elf64.elfHash((String*)symOrder.get(i)) % nbucket;
            chain.set(i, bucket.get(b)); // push onto the chain
            bucket.set(b, (Object*)Number.withU32(i));
            }
        p32(nbucket);
        p32(nsym);
        for (u32 i = (u32)0; i < nbucket; i = i + (u32)1)
            p32(((Number*)bucket.get(i)).asU32());
        for (u32 i = (u32)0; i < nsym; i = i + (u32)1)
            p32(((Number*)chain.get(i)).asU32());

        padTo(relaOff);
        // R_X86_64_RELATIVE
        for (u32 i = (u32)0; i < absFixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)absFixups.get(i);
            u32 target = (Elf64.inSet(dataSet, f.symbol()) ? dataAddr : textAddr) + ((Number*)symbols.get((Hashable*)f.symbol())).asU32() + (u32)f.addend();
            p64(dataAddr + f.offset());
            p64((u32)R_X86_64_RELATIVE);
            p64(target);
            }
        // R_X86_64_GLOB_DAT
        for (u32 i = (u32)0; i < imports.count(); i = i + (u32)1)
            {
            u32 symIdx = (u32)1 + exports.count() + i;
            p64(gotOff + i * (u32)8);
            // r_info is (sym << 32) | type; p64 writes a 32-bit low half and a
            // zero high half, so the two words go out by hand.
            p32((u32)R_X86_64_GLOB_DAT);
            p32(symIdx);
            p64((u32)0);
            }

        padTo(textOff);
        for (u32 i = (u32)0; i < text.length(); i = i + (u32)1)
            p8((u32)text.byteAt(i));
        padTo(gotOff);
        for (u32 i = (u32)0; i < imports.count(); i = i + (u32)1)
            p64((u32)0);
        for (u32 i = (u32)0; i < absGot.count(); i = i + (u32)1)
            {
            Object* v = symbols.get((Hashable*)absGot.get(i));
            p64(v == (Object*)0 ? (u32)0 : ((Number*)v).asU32());
            }

        padTo(dynOff);
        for (u32 i = (u32)0; i < neededOff.count(); i = i + (u32)1)
            dyn((u32)DT_NEEDED, ((Number*)neededOff.get(i)).asU32());
        if (!isExec)
            dyn((u32)DT_SONAME, sonameOff);
        if (hasRunpath)
            dyn((u32)DT_RUNPATH, runpathOff);
        dyn((u32)DT_HASH, hashOff);
        dyn((u32)DT_STRTAB, strOffB);
        dyn((u32)DT_SYMTAB, symOffB);
        dyn((u32)DT_STRSZ, dynstr.count());
        dyn((u32)DT_SYMENT, (u32)SYM_SZ);
        dyn((u32)DT_RELA, relaOff);
        dyn((u32)DT_RELASZ, nRela * (u32)RELA_SZ);
        dyn((u32)DT_RELAENT, (u32)RELA_SZ);
        dyn((u32)DT_NULL, (u32)0);

        padTo(dataAddr);
        for (u32 i = (u32)0; i < dataFileSz; i = i + (u32)1)
            p8((u32)data.byteAt(i));

        // ── section headers ──────────────────────────────────────────────
        // ld.so reads program headers only and never looks at these, but
        // without them `readelf -S`, `nm` and gdb see an object with no
        // sections at all. They cost a few hundred bytes at the end.
        //
        // .symtab lists every DEFINED symbol, not just the exported ones
        // .dynsym carries — the difference between `nm` showing an API and
        // showing the internals you need when something faults inside.
        Array* defNames = new Array();
        Array* dk = symbols.allKeys();
        for (u32 i = (u32)0; i < dk.count(); i = i + (u32)1)
            defNames.add(dk.get(i));
        Elf64.sortStrings(defNames);
        Array* strtab = new Array();
        strtab.add((Object*)Number.withU32((u32)0));
        Array* symtab = new Array();
        for (u32 i = (u32)0; i < (u32)SYM_SZ; i = i + (u32)1)
            symtab.add((Object*)Number.withU32((u32)0)); // the null symbol
        for (u32 i = (u32)0; i < defNames.count(); i = i + (u32)1)
            {
            String* n = (String*)defNames.get(i);
            bool inData = Elf64.inSet(dataSet, n);
            Elf64.u32Into(symtab, strtab.count());
            for (u32 b = (u32)0; b < n.byteLength(); b = b + (u32)1)
                strtab.add((Object*)Number.withU32((u32)n.byteAt(b)));
            strtab.add((Object*)Number.withU32((u32)0));
            symtab.add((Object*)Number.withU32(((u32)STB_GLOBAL << (u32)4) | (inData ? (u32)STT_OBJECT : (u32)STT_FUNC)));
            symtab.add((Object*)Number.withU32((u32)0));
            // .text and .data are sections 5 and 6 in the list built below; the
            // two are named together rather than left as bare numbers in two
            // places that have to be kept in step.
            u32 sect = inData ? (u32)6 : (u32)5;
            symtab.add((Object*)Number.withU32(sect & (u32)$FF));
            symtab.add((Object*)Number.withU32(sect >> (u32)8));
            Elf64.u32Into(symtab, (inData ? dataAddr : textAddr) + ((Number*)symbols.get((Hashable*)n)).asU32());
            Elf64.u32Into(symtab, (u32)0);
            Elf64.u32Into(symtab, (u32)0);
            Elf64.u32Into(symtab, (u32)0); // st_size
            }

        // The non-allocated section CONTENTS, then their offsets.
        u32 symtabOff = roundUpTo(_out.length(), (u32)8);
        padTo(symtabOff);
        for (u32 i = (u32)0; i < symtab.count(); i = i + (u32)1)
            p8(((Number*)symtab.get(i)).asU32());
        u32 strtabOff = _out.length();
        for (u32 i = (u32)0; i < strtab.count(); i = i + (u32)1)
            p8(((Number*)strtab.get(i)).asU32());
        u32 ifaceOff = _out.length();
        if (hasIface)
            for (u32 i = (u32)0; i < iface.count(); i = i + (u32)1)
                p8(((Number*)iface.get(i)).asU32());

        // The section-name table, then the headers themselves.
        Array* names = new Array();
        names.add((Object*)String.withCString(""));
        names.add((Object*)String.withCString(".dynsym"));
        names.add((Object*)String.withCString(".dynstr"));
        names.add((Object*)String.withCString(".hash"));
        names.add((Object*)String.withCString(".rela.dyn"));
        names.add((Object*)String.withCString(".text"));
        names.add((Object*)String.withCString(".data"));
        names.add((Object*)String.withCString(".got"));
        names.add((Object*)String.withCString(".dynamic"));
        names.add((Object*)String.withCString(".symtab"));
        names.add((Object*)String.withCString(".strtab"));
        if (hasIface)
            names.add((Object*)String.withCString(".xtc.iface"));
        names.add((Object*)String.withCString(".shstrtab"));
        Array* shstr = new Array();
        shstr.add((Object*)Number.withU32((u32)0));
        Map* shName = new Map();
        for (u32 i = (u32)1; i < names.count(); i = i + (u32)1)
            Elf64.internStr(shstr, shName, (String*)names.get(i));
        u32 shstrOff = _out.length();
        for (u32 i = (u32)0; i < shstr.count(); i = i + (u32)1)
            p8(((Number*)shstr.get(i)).asU32());

        u32 shOff = roundUpTo(_out.length(), (u32)8);
        padTo(shOff);
        u32 nsec = names.count();
        u32 shstrIdx = nsec - (u32)1;
        // name, type, flags, addr, offset, size, link, info, align, entsize.
        shdrE((u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0);
        // sh_link of .dynsym is its string table; sh_info the first global
        // index — everything we export is global, so that is 1.
        shdrE(Elf64.lookupStr(shName, (String*)names.get((u32)1)), (u32)11, (u32)2,
              symOffB, symOffB, nsym * (u32)SYM_SZ, (u32)2, (u32)1, (u32)8, (u32)SYM_SZ);
        shdrE(Elf64.lookupStr(shName, (String*)names.get((u32)2)), (u32)3, (u32)2,
              strOffB, strOffB, dynstr.count(), (u32)0, (u32)0, (u32)1, (u32)0);
        shdrE(Elf64.lookupStr(shName, (String*)names.get((u32)3)), (u32)5, (u32)2,
              hashOff, hashOff, hashSz, (u32)1, (u32)0, (u32)8, (u32)4);
        shdrE(Elf64.lookupStr(shName, (String*)names.get((u32)4)), (u32)4, (u32)2,
              relaOff, relaOff, nRela * (u32)RELA_SZ, (u32)1, (u32)0, (u32)8, (u32)RELA_SZ);
        shdrE(Elf64.lookupStr(shName, (String*)names.get((u32)5)), (u32)1, (u32)6,
              textOff, textOff, textLen, (u32)0, (u32)0, (u32)16, (u32)0);
        shdrE(Elf64.lookupStr(shName, (String*)names.get((u32)6)), (u32)1, (u32)3,
              dataAddr, dataAddr, data.length(), (u32)0, (u32)0, (u32)16, (u32)0);
        shdrE(Elf64.lookupStr(shName, (String*)names.get((u32)7)), (u32)1, (u32)3,
              gotOff, gotOff, ngot * (u32)8, (u32)0, (u32)0, (u32)8, (u32)8);
        shdrE(Elf64.lookupStr(shName, (String*)names.get((u32)8)), (u32)6, (u32)3,
              dynOff, dynOff, nDyn * (u32)DYN_SZ, (u32)2, (u32)0, (u32)8, (u32)DYN_SZ);
        u32 strtabIdx = (u32)10;
        shdrE(Elf64.lookupStr(shName, (String*)names.get((u32)9)), (u32)2, (u32)0,
              (u32)0, symtabOff, symtab.count(), strtabIdx, (u32)1, (u32)8, (u32)SYM_SZ);
        shdrE(Elf64.lookupStr(shName, (String*)names.get((u32)10)), (u32)3, (u32)0,
              (u32)0, strtabOff, strtab.count(), (u32)0, (u32)0, (u32)1, (u32)0);
        if (hasIface)
            shdrE(Elf64.lookupStr(shName, (String*)names.get((u32)11)), (u32)1, (u32)0,
                  (u32)0, ifaceOff, iface.count(), (u32)0, (u32)0, (u32)1, (u32)0);
        shdrE(Elf64.lookupStr(shName, (String*)names.get(shstrIdx)), (u32)3, (u32)0,
              (u32)0, shstrOff, shstr.count(), (u32)0, (u32)0, (u32)1, (u32)0);

        // Patch the header fields that could only be known at the end.
        if (isExec)
            patch32(entryField, textAddr + ((Number*)symbols.get((Hashable*)entry)).asU32());
        patch32(shoffField, shOff);
        patch16(shnumField, nsec);
        patch16(shnumField + (u32)2, shstrIdx);
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

    // A section header, in the gABI's field order.
    void shdrE(u32 name, u32 type, u32 flags, u32 addr, u32 off, u32 size,
               u32 link, u32 info, u32 align, u32 entsize)
        {
        p32(name);
        p32(type);
        p64(flags);
        p64(addr);
        p64(off);
        p64(size);
        p32(link);
        p32(info);
        p64(align);
        p64(entsize);
        }

    // Overwrite a 32-bit field already emitted — e_entry and e_shoff cannot be
    // known until the file is laid out.
    void patch32(u32 at, u32 v)
        {
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            _out.setByteAt(at + i, (u8)((v >> ((u32)8 * i)) & (u32)$FF));
        }
    void patch16(u32 at, u32 v)
        {
        _out.setByteAt(at, (u8)(v & (u32)$FF));
        _out.setByteAt(at + (u32)1, (u8)((v >> (u32)8) & (u32)$FF));
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

    static u32 internStr(Array* blob, Map* off, String* s)
        {
        Object* have = off.get((Hashable*)s);
        if (have != (Object*)0)
            return ((Number*)have).asU32();
        u32 at = blob.count();
        off.set((Hashable*)s, (Object*)Number.withU32(at));
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            blob.add((Object*)Number.withU32((u32)s.byteAt(i)));
        blob.add((Object*)Number.withU32((u32)0));
        return at;
        }

    static u32 lookupStr(Map* off, String* s)
        {
        Object* have = off.get((Hashable*)s);
        return have == (Object*)0 ? (u32)0 : ((Number*)have).asU32();
        }

    // ── ET_REL: the object `-c` writes ───────────────────────────────────
    //
    // Separate compilation, x86-64. The mirror of `objectFromData` next door,
    // which READS one: what this writes is what that has to be able to read,
    // and what a foreign linker has to accept.
    //
    // Only two sections carry content — .text and .data — because that is all
    // the assembler produces. Everything else is bookkeeping: two relocation
    // tables (one per patched section), the symbol table, and two string
    // tables.
    Data* objectFromText(Array* text, Array* data, Map* symbols, Array* dataSyms,
                         Array* globalSyms, Map* commons, Array* fixups)
        {
        if (data == (Array*)0)
            data = new Array();
        if (commons == (Map*)0)
            commons = new Map();

        // ELF requires every STB_LOCAL symbol to precede every global, and
        // `sh_info` of .symtab to be the index of the FIRST global — so the
        // order is locals, defined globals (text then data), undefined. Sorted
        // within each group, so two builds of one input cannot differ by a
        // map's enumeration order.
        Array* locals = new Array();
        Array* defText = new Array();
        Array* defData = new Array();
        Array* names = symbols.allKeys();
        Elf64.sortStrings(names);
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* n = (String*)names.get(i);
            if (n.hasPrefix(String.withCString(".L")))
                continue; // already resolved
            if (!Elf64.hasName(globalSyms, n))
                {
                locals.add((Object*)n);
                continue;
                }
            if (Elf64.hasName(dataSyms, n))
                defData.add((Object*)n);
            else
                defText.add((Object*)n);
            }
        Array* undef = new Array();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)fixups.get(i);
            if (f.symbol() == (String*)0)
                continue;
            if (symbols.get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            if (!Elf64.hasName(undef, f.symbol()))
                undef.add((Object*)f.symbol());
            }
        Elf64.sortStrings(undef);

        Array* commonNames = commons.allKeys();
        Elf64.sortStrings(commonNames);
        Array* order = new Array();
        for (u32 i = (u32)0; i < locals.count(); i = i + (u32)1)
            order.add(locals.get(i));
        u32 firstGlobal = order.count() + (u32)1; // +1 for the null symbol
        for (u32 i = (u32)0; i < defText.count(); i = i + (u32)1)
            order.add(defText.get(i));
        for (u32 i = (u32)0; i < defData.count(); i = i + (u32)1)
            order.add(defData.get(i));
        for (u32 i = (u32)0; i < commonNames.count(); i = i + (u32)1)
            order.add(commonNames.get(i));
        for (u32 i = (u32)0; i < undef.count(); i = i + (u32)1)
            order.add(undef.get(i));

        Array* strtab = new Array();
        strtab.add((Object*)Number.withU32((u32)0));
        // Function sizes (st_size) for defined TEXT symbols, so the linker can
        // GC unreferenced functions (bug 196 Stage B). Functions are the non-.L
        // text symbols; sorted by offset they delimit one another, and the last
        // runs to the end of .text. clang objects already carry st_size — this
        // gives OUR objects the same, uniformly readable at link.
        Array* fsOff = new Array();
        Array* fsName = new Array();
        for (u32 i = (u32)0; i < defText.count(); i = i + (u32)1)
            {
            String* n = (String*)defText.get(i);
            Object* o = symbols.get((Hashable*)n);
            if (o == (Object*)0)
                continue;
            fsOff.add((Object*)Number.withU32(((Number*)o).asU32()));
            fsName.add((Object*)n);
            }
        for (u32 i = (u32)0; i < locals.count(); i = i + (u32)1)
            {
            String* n = (String*)locals.get(i);
            if (Elf64.hasName(dataSyms, n))
                continue;
            Object* o = symbols.get((Hashable*)n);
            if (o == (Object*)0)
                continue;
            fsOff.add((Object*)Number.withU32(((Number*)o).asU32()));
            fsName.add((Object*)n);
            }
        // insertion sort by offset (stable, small n per object)
        for (u32 i = (u32)1; i < fsOff.count(); i = i + (u32)1)
            {
            u32 vo = ((Number*)fsOff.get(i)).asU32();
            String* vn = (String*)fsName.get(i);
            u32 j = i;
            while (j > (u32)0 && ((Number*)fsOff.get(j - (u32)1)).asU32() > vo)
                {
                fsOff.set(j, fsOff.get(j - (u32)1));
                fsName.set(j, fsName.get(j - (u32)1));
                j = j - (u32)1;
                }
            fsOff.set(j, (Object*)Number.withU32(vo));
            fsName.set(j, (Object*)vn);
            }
        Map* funcSize = new Map();
        for (u32 i = (u32)0; i < fsOff.count(); i = i + (u32)1)
            {
            u32 o0 = ((Number*)fsOff.get(i)).asU32();
            u32 o1 = (u32)text.count();
            for (u32 j = i + (u32)1; j < fsOff.count(); j = j + (u32)1) // next DISTINCT offset (aliases share one)
                if (((Number*)fsOff.get(j)).asU32() > o0)
                    {
                    o1 = ((Number*)fsOff.get(j)).asU32();
                    break;
                    }
            funcSize.set((Hashable*)(String*)fsName.get(i), (Object*)Number.withU32(o1 >= o0 ? o1 - o0 : (u32)0));
            }
        // The same for DATA symbols, so the linker's dead-data GC can split an
        // object's .data at every symbol (a size-0 data symbol is never a unit
        // boundary — it cannot say where it ends).
        Array* dsOff = new Array();
        Array* dsName = new Array();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* n = (String*)names.get(i);
            if (n.hasPrefix(String.withCString(".L")) || !Elf64.hasName(dataSyms, n))
                continue;
            Object* o = symbols.get((Hashable*)n);
            if (o == (Object*)0)
                continue;
            dsOff.add((Object*)Number.withU32(((Number*)o).asU32()));
            dsName.add((Object*)n);
            }
        for (u32 i = (u32)1; i < dsOff.count(); i = i + (u32)1)
            {
            u32 vo = ((Number*)dsOff.get(i)).asU32();
            String* vn = (String*)dsName.get(i);
            u32 j = i;
            while (j > (u32)0 && ((Number*)dsOff.get(j - (u32)1)).asU32() > vo)
                {
                dsOff.set(j, dsOff.get(j - (u32)1));
                dsName.set(j, dsName.get(j - (u32)1));
                j = j - (u32)1;
                }
            dsOff.set(j, (Object*)Number.withU32(vo));
            dsName.set(j, (Object*)vn);
            }
        for (u32 i = (u32)0; i < dsOff.count(); i = i + (u32)1)
            {
            u32 o0 = ((Number*)dsOff.get(i)).asU32();
            u32 o1 = (u32)data.count();
            for (u32 j = i + (u32)1; j < dsOff.count(); j = j + (u32)1)
                if (((Number*)dsOff.get(j)).asU32() > o0)
                    {
                    o1 = ((Number*)dsOff.get(j)).asU32();
                    break;
                    }
            funcSize.set((Hashable*)(String*)dsName.get(i), (Object*)Number.withU32(o1 >= o0 ? o1 - o0 : (u32)0));
            }

        Array* symtab = new Array();
        for (u32 i = (u32)0; i < (u32)SYM_SZ; i = i + (u32)1)
            symtab.add((Object*)Number.withU32((u32)0)); // the null symbol
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            String* n = (String*)order.get(i);
            Object* com = commons.get((Hashable*)n);
            Elf64.put32In(symtab, strtab.count());
            Elf64.putStr(strtab, n);
            if (com != (Object*)0)
                {
                // A COMMON (tentative def): SHN_COMMON (0xFFF2), st_value =
                // required alignment, st_size = byte size; GLOBAL / OBJECT. The
                // linker allocates one slot and every unit binds to it.
                Array* info = (Array*)com;
                symtab.add((Object*)Number.withU32(((u32)1 << (u32)4) | (u32)1)); // GLOBAL|OBJECT
                symtab.add((Object*)Number.withU32((u32)0));                      // st_other
                Elf64.put16In(symtab, (u32)$FFF2);                                // SHN_COMMON
                Elf64.put64In(symtab, ((Number*)info.get((u32)1)).asU32());       // st_value = align
                Elf64.put64In(symtab, ((Number*)info.get((u32)0)).asU32());       // st_size  = size
                continue;
                }
            Object* defAt = symbols.get((Hashable*)n);
            bool isUndef = defAt == (Object*)0;
            bool inData = Elf64.hasName(dataSyms, n);
            u32 bind = (isUndef || Elf64.hasName(globalSyms, n)) ? (u32)1 : (u32)0;
            u32 kind = isUndef ? (u32)0 : (inData ? (u32)1 : (u32)2); // NOTYPE/OBJECT/FUNC
            symtab.add((Object*)Number.withU32((bind << (u32)4) | kind));
            symtab.add((Object*)Number.withU32((u32)0)); // st_other
            Elf64.put16In(symtab, isUndef ? (u32)0 : (inData ? (u32)2 : (u32)1));
            Elf64.put64In(symtab, isUndef ? (u32)0 : ((Number*)defAt).asU32());
            Object* fsz = isUndef ? (Object*)0 : funcSize.get((Hashable*)n);
            Elf64.put64In(symtab, fsz != (Object*)0 ? ((Number*)fsz).asU32() : (u32)0); // st_size (symbol extent, bug 196)
            }
        Map* symIndex = new Map();
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            symIndex.set((Hashable*)(String*)order.get(i), (Object*)Number.withU32(i + (u32)1));

        // Relocations, split by the section the fixup patches. An Abs64 fixup
        // is a `.quad <symbol>` inside .data; the PC-relative kinds patch an
        // instruction in .text.
        Array* textRel = new Array();
        Array* dataRel = new Array();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            X86Fixup* f = (X86Fixup*)fixups.get(i);
            if (f.symbol() == (String*)0)
                continue;
            Object* si = symIndex.get((Hashable*)f.symbol());
            if (si == (Object*)0)
                continue; // nothing names it
            u32 idx = ((Number*)si).asU32();
            if (f.kind() == (u32)X86FIX_ABS64)
                {
                if (f.offset() + (u32)8 > data.count())
                    {
                    fail(String.withCString("abs64 fixup past the end of .data: ")
                             .appending(f.symbol()));
                    return (Data*)0;
                    }
                Elf64.put64In(dataRel, f.offset());
                Elf64.put32In(dataRel, (u32)R_X86_64_64);
                Elf64.put32In(dataRel, idx);
                Elf64.putI64In(dataRel, f.addend());
                continue;
                }
            if (f.offset() + (u32)4 > text.count())
                {
                fail(String.withCString("pc32 fixup past the end of .text: ")
                         .appending(f.symbol()));
                return (Data*)0;
                }
            // PLT32 for a call/jmp target, PC32 for a data reference — what
            // clang emits. Both resolve identically for a DEFINED symbol, and a
            // linker that treats them differently expects the distinction.
            u32 rt = f.kind() == (u32)X86FIX_REL32 ? (u32)R_X86_64_PLT32 : (u32)R_X86_64_PC32;
            Elf64.put64In(textRel, f.offset());
            Elf64.put32In(textRel, rt);
            Elf64.put32In(textRel, idx);
            Elf64.putI64In(textRel, f.addend());
            }

        Array* secNames = new Array();
        secNames.add((Object*)String.withCString(""));
        secNames.add((Object*)String.withCString(".text"));
        secNames.add((Object*)String.withCString(".data"));
        secNames.add((Object*)String.withCString(".rela.text"));
        secNames.add((Object*)String.withCString(".rela.data"));
        secNames.add((Object*)String.withCString(".symtab"));
        secNames.add((Object*)String.withCString(".strtab"));
        secNames.add((Object*)String.withCString(".shstrtab"));
        Array* shstr = new Array();
        shstr.add((Object*)Number.withU32((u32)0));
        Array* shName = new Array();
        for (u32 i = (u32)0; i < secNames.count(); i = i + (u32)1)
            {
            String* n = (String*)secNames.get(i);
            if (n.byteLength() == (u32)0)
                {
                shName.add((Object*)Number.withU32((u32)0));
                continue;
                }
            shName.add((Object*)Number.withU32(shstr.count()));
            Elf64.putStr(shstr, n);
            }

        u32 off = (u32)EHDR_SZ;
        u32 textOff = Elf64.roundUpTo(off, (u32)16);
        off = textOff + text.count();
        u32 dataOff = Elf64.roundUpTo(off, (u32)8);
        off = dataOff + data.count();
        u32 trelOff = Elf64.roundUpTo(off, (u32)8);
        off = trelOff + textRel.count();
        u32 drelOff = Elf64.roundUpTo(off, (u32)8);
        off = drelOff + dataRel.count();
        u32 symOff = Elf64.roundUpTo(off, (u32)8);
        off = symOff + symtab.count();
        u32 strOff = off;
        off = strOff + strtab.count();
        u32 shstOff = off;
        off = shstOff + shstr.count();
        u32 shOff = Elf64.roundUpTo(off, (u32)8);

        _out = new Data();
        p8((u32)$7F);
        p8((u32)'E');
        p8((u32)'L');
        p8((u32)'F');
        p8((u32)2);
        p8((u32)1);
        p8((u32)1);
        for (u32 i = (u32)0; i < (u32)9; i = i + (u32)1)
            p8((u32)0);
        p16((u32)1); // ET_REL
        p16((u32)EM_X86_64);
        p32((u32)1); // EV_CURRENT
        p64((u32)0);
        p64((u32)0); // e_entry, e_phoff
        p64(shOff);
        p32((u32)0); // e_flags
        p16((u32)EHDR_SZ);
        p16((u32)0);
        p16((u32)0); // no program headers
        p16((u32)64);
        p16(secNames.count());
        p16(secNames.count() - (u32)1);

        padTo(textOff);
        Elf64.appendAll(_out, text);
        padTo(dataOff);
        Elf64.appendAll(_out, data);
        padTo(trelOff);
        Elf64.appendAll(_out, textRel);
        padTo(drelOff);
        Elf64.appendAll(_out, dataRel);
        padTo(symOff);
        Elf64.appendAll(_out, symtab);
        padTo(strOff);
        Elf64.appendAll(_out, strtab);
        padTo(shstOff);
        Elf64.appendAll(_out, shstr);
        padTo(shOff);

        objShdr(shName, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0);
        // SHF_ALLOC|SHF_EXECINSTR, SHF_ALLOC|SHF_WRITE
        objShdr(shName, (u32)1, (u32)1, (u32)6, textOff, text.count(), (u32)0, (u32)0, (u32)16, (u32)0);
        objShdr(shName, (u32)2, (u32)1, (u32)3, dataOff, data.count(), (u32)0, (u32)0, (u32)8, (u32)0);
        objShdr(shName, (u32)3, (u32)4, (u32)0, trelOff, textRel.count(),
                (u32)5, (u32)1, (u32)8, (u32)RELA_SZ);
        objShdr(shName, (u32)4, (u32)4, (u32)0, drelOff, dataRel.count(),
                (u32)5, (u32)2, (u32)8, (u32)RELA_SZ);
        objShdr(shName, (u32)5, (u32)2, (u32)0, symOff, symtab.count(),
                (u32)6, firstGlobal, (u32)8, (u32)SYM_SZ);
        objShdr(shName, (u32)6, (u32)3, (u32)0, strOff, strtab.count(), (u32)0, (u32)0, (u32)1, (u32)0);
        objShdr(shName, (u32)7, (u32)3, (u32)0, shstOff, shstr.count(), (u32)0, (u32)0, (u32)1, (u32)0);
        return _out;
        }

    // name, type, flags, addr(always 0 in an object), offset, size, link, info,
    // align, entsize.
    void objShdr(Array* shName, u32 nameIdx, u32 kind, u32 flags, u32 offset, u32 size,
                 u32 link, u32 info, u32 align, u32 entsz)
        {
        p32(((Number*)shName.get(nameIdx)).asU32());
        p32(kind);
        p64(flags);
        p64((u32)0);
        p64(offset);
        p64(size);
        p32(link);
        p32(info);
        p64(align);
        p64(entsz);
        }

    static bool hasName(Array* a, String* n)
        {
        for (u32 i = (u32)0; a != (Array*)0 && i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(n))
                return true;
        return false;
        }

    static void appendAll(Data* dst, Array* src)
        {
        for (u32 i = (u32)0; i < src.count(); i = i + (u32)1)
            dst.appendByte((u8)((Number*)src.get(i)).asU32());
        }

    static void putStr(Array* blob, String* s)
        {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            blob.add((Object*)Number.withU32((u32)s.byteAt(i)));
        blob.add((Object*)Number.withU32((u32)0));
        }

    static void put16In(Array* b, u32 v)
        {
        b.add((Object*)Number.withU32(v & (u32)$FF));
        b.add((Object*)Number.withU32((v >> (u32)8) & (u32)$FF));
        }

    static void put32In(Array* b, u32 v)
        {
        Elf64.put16In(b, v);
        Elf64.put16In(b, v >> (u32)16);
        }

    static void put64In(Array* b, u32 v)
        {
        Elf64.put32In(b, v);
        Elf64.put32In(b, (u32)0);
        }

    // A SIGNED 64-bit addend: an r_addend of -4 is 0xFFFFFFFFFFFFFFFC, so the
    // high word is all ones rather than zero. Writing it as an unsigned 32 and
    // padding turned every PC-relative relocation into +4294967292.
    static void putI64In(Array* b, i32 v)
        {
        Elf64.put32In(b, (u32)v);
        Elf64.put32In(b, v < (i32)0 ? (u32)$FFFF_FFFF : (u32)0);
        }

    static void sortStrings(Array* a)
        {
        // O(n log n) quicksort by String.compare (was insertion sort). Equal
        // strings are byte-identical, so reordering them cannot change output.
        a.sort();
        }

    static bool inArray(Array* a, String* nm)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(nm))
                return true;
        return false;
        }

    // A name-set for O(1) membership — the linear inArray above is O(n) per
    // check, so scanning it once per symbol/fixup is O(n^2) and dominated a big
    // static link (blewit: minutes of String.equals). Build the set once.
    static Map* setOf(Array* a)
        {
        Map* m = new Map();
        for (u32 i = (u32)0; a != (Array*)0 && i < a.count(); i = i + (u32)1)
            m.set((Hashable*)(String*)a.get(i), (Object*)Number.withU32((u32)1));
        return m;
        }
    static bool inSet(Map* m, String* nm)
        {
        return m.get((Hashable*)nm) != (Object*)0;
        }

    // ── The image ────────────────────────────────────────────────────────
    void emitExec(Data* text, Data* data, Map* symbols, Array* dataSyms, u32 entryOffset)
        {
        bool hasData = data.length() > (u32)0;
        u32 nphdr = phdrCountFor(hasData);
        u32 textOff = textOffsetFor(nphdr);
        u32 textAddr = (u32)ELF_VBASE + textOff;
        u32 textEnd = textOff + text.length();
        u32 dataOff = dataOffsetFor(hasData, text.length());
        u32 dataAddr = (u32)ELF_VBASE + dataOff + (u32)ELF_PAGE;
        u32 dataFileSz = fileSizeOf(data);

        // ELF header.
        p8((u32)$7F);
        p8((u32)'E');
        p8((u32)'L');
        p8((u32)'F');
        p8((u32)2); // ELFCLASS64
        p8((u32)1); // ELFDATA2LSB
        p8((u32)1); // EI_VERSION
        p8((u32)0); // SYSV
        p8((u32)0);
        for (u32 i = (u32)0; i < (u32)7; i = i + (u32)1)
            p8((u32)0);
        p16((u32)2);  // ET_EXEC
        p16((u32)62); // EM_X86_64
        p32((u32)1);
        p64(textAddr + entryOffset); // e_entry
        p64((u32)EHDR_SZ);           // e_phoff
        p64((u32)0);                 // e_shoff, patched below
        p32((u32)0);
        p16((u32)EHDR_SZ);
        p16((u32)PHDR_SZ);
        p16(nphdr);
        p16((u32)SHDR_SZ);
        p16((u32)0);
        p16((u32)0);

        // Program headers. The text segment maps from file offset 0 so it also
        // covers the headers.
        p32((u32)1);
        p32((u32)4 | (u32)1); // PT_LOAD, R+X
        p64((u32)0);
        p64((u32)ELF_VBASE);
        p64((u32)ELF_VBASE);
        p64(textEnd);
        p64(textEnd);
        p64((u32)ELF_PAGE);
        if (hasData)
            {
            p32((u32)1);
            p32((u32)4 | (u32)2); // PT_LOAD, R+W
            p64(dataOff);
            p64(dataAddr);
            p64(dataAddr);
            p64(dataFileSz);    // p_filesz: trailing zeros unstored
            p64(data.length()); // p_memsz: the kernel zero-fills
            p64((u32)ELF_PAGE);
            }
        // PT_GNU_STACK, present with no PF_X so the stack is non-executable.
        p32((u32)$6474E551);
        p32((u32)4 | (u32)2);
        p64((u32)0);
        p64((u32)0);
        p64((u32)0);
        p64((u32)0);
        p64((u32)0);
        p64((u32)$10);

        padTo(textOff);
        _out.append(text);
        if (hasData)
            {
            padTo(dataOff);
            for (u32 i = (u32)0; i < dataFileSz; i = i + (u32)1)
                _out.appendByte(data.byteAt(i));
            }
        if (symbols.allKeys().count() == (u32)0)
            return;
        emitSymbolSections(text, data, symbols, dataSyms, textAddr, dataAddr,
                           textOff, dataOff);
        }

    // Split out for the arm64 frame budget: the section-name temporaries and
    // the table building together want more stack than one frame can address.
    void emitSymbolSections(Data* text, Data* data, Map* symbols, Array* dataSyms,
                            u32 textAddr, u32 dataAddr, u32 textOff, u32 dataOff)
        {
        // .symtab lists every defined symbol. Neither the kernel nor ld.so
        // reads any of it — but debugging a fault in a stripped binary means
        // disassembling by hand, which is exactly how long the sil/dil bug took
        // to find.
        Array* names = sortedNames(symbols);
        Map* dataSet = Elf64.setOf(dataSyms); // O(1) membership, was O(n^2)
        Array* strtab = new Array();
        strtab.add((Object*)Number.withU32((u32)0));
        Array* symtab = new Array();
        for (u32 i = (u32)0; i < (u32)24; i = i + (u32)1)
            symtab.add((Object*)Number.withU32((u32)0)); // the null symbol
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* n = (String*)names.get(i);
            bool inData = Elf64.inSet(dataSet, n);
            u32 nameOff = strtab.count();
            strInto(strtab, n);
            u32Into(symtab, nameOff);
            symtab.add((Object*)Number.withU32(((u32)1 << (u32)4) | (inData ? (u32)1 : (u32)2)));
            symtab.add((Object*)Number.withU32((u32)0));
            symtab.add((Object*)Number.withU32(inData ? (u32)2 : (u32)1)); // .data : .text
            symtab.add((Object*)Number.withU32((u32)0));
            u32 addr = (inData ? dataAddr : textAddr) + ((Number*)symbols.get((Hashable*)n)).asU32();
            u32Into(symtab, addr);
            u32Into(symtab, (u32)0);
            u32Into(symtab, (u32)0);
            u32Into(symtab, (u32)0);
            }

        Array* shstr = new Array();
        shstr.add((Object*)Number.withU32((u32)0));
        u32 nText = shstr.count();
        strInto(shstr, String.withCString(".text"));
        u32 nData = shstr.count();
        strInto(shstr, String.withCString(".data"));
        u32 nSymtab = shstr.count();
        strInto(shstr, String.withCString(".symtab"));
        u32 nStrtab = shstr.count();
        strInto(shstr, String.withCString(".strtab"));
        u32 nShstr = shstr.count();
        strInto(shstr, String.withCString(".shstrtab"));

        u32 symOff = roundUpTo(_out.length(), (u32)8);
        padTo(symOff);
        appendAll(symtab);
        u32 strOff = _out.length();
        appendAll(strtab);
        u32 shstrOff = _out.length();
        appendAll(shstr);
        u32 shOff = roundUpTo(_out.length(), (u32)8);
        padTo(shOff);

        shdr((u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0);
        shdr(nText, (u32)1, (u32)2 | (u32)4, textAddr, textOff, text.length(),
             (u32)0, (u32)0, (u32)64, (u32)0);
        shdr(nData, (u32)1, (u32)2 | (u32)1, dataAddr, dataOff, data.length(),
             (u32)0, (u32)0, (u32)16, (u32)0);
        // sh_info is the index of the first non-local symbol; every symbol here
        // is global, so that is 1 — the entry straight after the null one.
        shdr(nSymtab, (u32)2, (u32)0, (u32)0, symOff, symtab.count(),
             (u32)4, (u32)1, (u32)8, (u32)24);
        shdr(nStrtab, (u32)3, (u32)0, (u32)0, strOff, strtab.count(),
             (u32)0, (u32)0, (u32)1, (u32)0);
        shdr(nShstr, (u32)3, (u32)0, (u32)0, shstrOff, shstr.count(),
             (u32)0, (u32)0, (u32)1, (u32)0);

        // e_shoff, e_shnum and e_shstrndx were written as zero above.
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            _out.setByteAt((u32)$28 + i, (u8)((shOff >> ((u32)8 * i)) & (u32)$FF));
        _out.setByteAt((u32)$3C, (u8)((u32)6));
        _out.setByteAt((u32)$3D, (u8)((u32)0));
        _out.setByteAt((u32)$3E, (u8)((u32)5));
        _out.setByteAt((u32)$3F, (u8)((u32)0));
        }

    void shdr(u32 name, u32 type, u32 flags, u32 addr, u32 off, u32 size,
              u32 link, u32 info, u32 align, u32 entsz)
        {
        p32(name);
        p32(type);
        p64(flags);
        p64(addr);
        p64(off);
        p64(size);
        p32(link);
        p32(info);
        p64(align);
        p64(entsz);
        }

    void appendAll(Array* a)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            _out.appendByte((u8)((Number*)a.get(i)).asU32());
        }

    static void strInto(Array* a, String* s)
        {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            a.add((Object*)Number.withU32((u32)s.byteAt(i)));
        a.add((Object*)Number.withU32((u32)0));
        }

    static void u32Into(Array* a, u32 v)
        {
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            a.add((Object*)Number.withU32((v >> ((u32)8 * i)) & (u32)$FF));
        }

    static Array* sortedNames(Map* symbols)
        {
        // O(n log n) quicksort by String.compare (was an O(n^2) insertion
        // sort; the blewit symtab has thousands of names). Map keys are
        // unique, so the comparator never returns 0 for distinct elements
        // and the sorted order -- hence the emitted bytes -- is unchanged.
        Array* keys = symbols.allKeys();
        keys.sort();
        return keys;
        }
    }
