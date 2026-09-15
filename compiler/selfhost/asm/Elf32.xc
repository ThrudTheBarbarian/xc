// Elf32.xc — an ELF32 relocatable object, written by hand.
// =========================================================================
//
// self-hosting M11. The assembler turns the back end's `.s` into bytes; this
// puts those bytes in the container a linker will take. Together they replace
// the `arm-none-eabi-gcc` call the arm9 path makes today — which is the whole
// point, because the device has no gcc.
//
// It writes what an assembler writes and no more: `.text`, `.data`, `.bss` (as
// COMMON symbols), a symbol table, and one relocation section per relocated
// section. Not a linker — no dynamic sections, no PLT, no GOT. The linker is
// the next piece; this is what it eats.
//
// The oracle is the toolchain itself: hand the object to `arm-none-eabi-gcc`
// in place of the `.s` it would have assembled, and the program that comes out
// has to run and print the same thing. An object that is subtly wrong does not
// link, or links and crashes — either way it is not silent.
//
// Layout, in the order the bytes go out:
//
//   ELF header │ .text │ .data │ .rel.text │ .rel.data │ .symtab │ .strtab
//   │ .shstrtab │ section headers
//
// Everything is little-endian, which is what `EI_DATA = 1` says and what the
// A9 is.

#import "Foundation.xc"
#import "Arm32.xc"

// ── ET_DYN: what the XTOS loader takes ───────────────────────────────────
#define ELF32_PAGE $1000
#define R_ARM_GLOB_DAT $15
#define R_ARM_RELATIVE $17
#define VENEER_SZ 8
#define DT_NEEDED_T 1
#define DT_HASH_T 4
#define DT_STRTAB_T 5
#define DT_SYMTAB_T 6
#define DT_STRSZ_T 10
#define DT_SYMENT_T 11
#define DT_SONAME_T 14
#define DT_REL_T 17
#define DT_RELSZ_T 18
#define DT_RELENT_T 19

// One dynamic relocation the loader will apply.
class Elf32DynRel
    {
    u32 _addr;
    u32 _type;
    String* _symbol;
    void init(void)
        {
        _addr = (u32)0;
        _type = (u32)0;
        _symbol = (String*)0;
        }
    static Elf32DynRel* with(u32 a, u32 t, String* sym)
        {
        Elf32DynRel* d = new Elf32DynRel();
        d._addr = a;
        d._type = t;
        d._symbol = sym;
        return d;
        }
    u32 addr(void)
        {
        return _addr;
        }
    u32 type(void)
        {
        return _type;
        }
    String* symbol(void)
        {
        return _symbol;
        }
    }

    class Elf32
    {
    Array* _out; // Number@ per byte
    bool _failed;
    String* _why;

    void init(void)
        {
        _failed = false;
        _why = (String*)0;
        }

    bool failed(void)
        {
        return _failed;
        }
    String* why(void)
        {
        return _why;
        }

    void byte(u32 v)
        {
        _out.add((Object*)Number.with(v & (u32)$FF));
        }
    void half(u32 v)
        {
        byte(v);
        byte(v >> 8);
        }
    void word(u32 v)
        {
        byte(v);
        byte(v >> 8);
        byte(v >> 16);
        byte(v >> 24);
        }

    void bytesFrom(Array* src)
        {
        for (u32 i = (u32)0; i < src.count(); i = i + (u32)1)
            byte(((Number*)src.get(i)).asU32());
        }

    void padTo(u32 n)
        {
        while (_out.count() < n)
            byte((u32)0);
        }

    static u32 align4(u32 v)
        {
        return (v + (u32)3) & ~(u32)3;
        }

    // ── The string table ─────────────────────────────────────────────────
    // Names are stored once, NUL-separated, and referred to by byte offset.
    // Index 0 is always the empty string, which is what a nameless symbol or
    // section points at.
    Array* _strBytes;
    Map* _strOffsets;

    void strTableInit(void)
        {
        _strBytes = new Array();
        _strOffsets = new Map();
        _strBytes.add((Object*)Number.with((u32)0));
        }

    u32 strAdd(String* s)
        {
        if (s == 0 || s.byteLength() == (u32)0)
            return (u32)0;
        Object* have = _strOffsets.get((Hashable*)s);
        if (have != 0)
            return ((Number*)have).asU32();
        u32 at = _strBytes.count();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            _strBytes.add((Object*)Number.with((u32)s.byteAt(i)));
        _strBytes.add((Object*)Number.with((u32)0));
        _strOffsets.set((Hashable*)s, (Object*)Number.with(at));
        return at;
        }

    // ── Writing ──────────────────────────────────────────────────────────
    // `text`/`data` are the assembled payloads, `syms` the symbol table and
    // `relocs` the relocations, exactly as the assembler recorded them.
    // ── The SHARED OBJECT (ET_DYN) the XTOS loader takes ─────────────────
    //
    // The arm9 link, in-house: no arm-none-eabi-gcc, no ld, no libgcc. The
    // assembler encodes, this lays the image out and writes the dynamic
    // sections the loader reads.
    //
    // Layout: one R+X segment holding code, veneers and the read-only dynamic
    // metadata; one R+W segment holding .data and .bss. Both mapped 1:1, so a
    // file offset IS a virtual address and the two never have to be tracked
    // separately.
    Array* sharedObject(Array* textIn, Array* dataIn, Array* syms, Array* relocs,
                        Array* needed, String* soname, Array* iface)
        {
        Array* text = new Array();
        for (u32 i = (u32)0; i < textIn.count(); i = i + (u32)1)
            text.add(textIn.get(i));
        Array* data = new Array();
        for (u32 i = (u32)0; i < dataIn.count(); i = i + (u32)1)
            data.add(dataIn.get(i));
        // ONE DT_NEEDED per library. The driver builds this list from two
        // sources — the `#import <Lib>` dependencies and the device sysroot
        // scan — and libc.so is in both, so an arm9 program recorded it twice.
        // Harmless at load (a second mapping of a library already mapped) but
        // it is a contract spelled in two places, and deduplicating at the
        // point of writing means neither caller has to remember.
        Array* uniq = new Array();
        for (u32 i = (u32)0; needed != (Array*)0 && i < needed.count(); i = i + (u32)1)
            {
            String* n = (String*)needed.get(i);
            if (n != (String*)0 && n.byteLength() > (u32)0 && !Elf32.hasString(uniq, n))
                uniq.add((Object*)n);
            }
        needed = uniq;

        u32 textBase = (u32)ELF32_PAGE; // leave the header page
        u32 codeSize = text.count();

        // COMMON symbols get storage of their own, after .data. Their `value`
        // is an ALIGNMENT until here and an offset afterwards — the one place
        // those two fields swap meaning.
        u32 bssSize = (u32)0;
        for (u32 i = (u32)0; i < syms.count(); i = i + (u32)1)
            {
            AsmSymbol* sy = (AsmSymbol*)syms.get(i);
            if (sy.section() != (u32)3)
                continue;
            sy.setValue(bssSize);
            bssSize = align4(bssSize + sy.size());
            }

        // Imports: every symbol a relocation names that this image does not
        // define. Each gets a veneer, and the veneer's word is what the loader
        // resolves.
        Array* imports = new Array();
        for (u32 i = (u32)0; i < relocs.count(); i = i + (u32)1)
            {
            AsmReloc* r = (AsmReloc*)relocs.get(i);
            AsmSymbol* sy = Elf32.findSym(syms, r.symbol());
            if (sy != (AsmSymbol*)0 && sy.section() != (u32)0)
                continue;
            if (!Elf32.hasString(imports, r.symbol()))
                imports.add((Object*)r.symbol());
            }
        u32 veneerBase = align4(textBase + codeSize);
        u32 textSize = (veneerBase - textBase) + imports.count() * (u32)VENEER_SZ;

        // The dynamic symbol table: what this image exports, then what it
        // imports. An import is an entry with no section — SHN_UNDEF is what
        // sends the loader looking for it.
        Array* dyn = new Array();
        for (u32 i = (u32)0; i < syms.count(); i = i + (u32)1)
            {
            AsmSymbol* sy = (AsmSymbol*)syms.get(i);
            if (sy.isGlobal() && sy.section() != (u32)0)
                dyn.add((Object*)sy);
            }
        for (u32 i = (u32)0; i < imports.count(); i = i + (u32)1)
            dyn.add((Object*)AsmSymbol.named((String*)imports.get(i)));

        Array* dynstr = new Array();
        dynstr.add((Object*)Number.with((u32)0));
        Array* neededOff = new Array();
        for (u32 i = (u32)0; i < needed.count(); i = i + (u32)1)
            {
            neededOff.add((Object*)Number.with(dynstr.count()));
            Elf32.strInto(dynstr, (String*)needed.get(i));
            }
        u32 sonameOff = (u32)0;
        bool hasSoname = soname != (String*)0 && soname.byteLength() > (u32)0;
        if (hasSoname)
            {
            sonameOff = dynstr.count();
            Elf32.strInto(dynstr, soname);
            }
        Array* nameOff = new Array();
        for (u32 i = (u32)0; i < dyn.count(); i = i + (u32)1)
            {
            nameOff.add((Object*)Number.with(dynstr.count()));
            Elf32.strInto(dynstr, ((AsmSymbol*)dyn.get(i)).name());
            }

        u32 symCount = dyn.count() + (u32)1; // + the null entry
        u32 nbucket = (u32)1;                // one chain is enough
        u32 dynCount = (u32)9 + needed.count() + (hasSoname ? (u32)1 : (u32)0);

        u32 off = align4(textBase + textSize);
        u32 hashAddr = off;
        off = off + (u32)4 * ((u32)2 + nbucket + symCount);
        u32 symAddr = align4(off);
        off = symAddr + symCount * (u32)16;
        u32 strAddr = off;
        off = off + dynstr.count();

        // The relocation COUNT has to be known before the layout that holds
        // them, and the relocations depend on the layout — so they are applied
        // once against a PROVISIONAL data base purely to count, and again below
        // against the final one. Patching the image twice would be cheaper and
        // far easier to get wrong.
        u32 provisional = alignPage(off + (u32)64);
        Array* t0 = Elf32.copyBytes(text);
        Array* d0 = Elf32.copyBytes(data);
        Array* count0 = new Array();
        if (!applyRelocs(relocs, syms, t0, d0, textBase, provisional, provisional,
                         imports, veneerBase, count0))
            return (Array*)0;
        u32 nDynRel = count0.count() + imports.count();

        u32 relAddr = align4(off);
        off = relAddr + nDynRel * (u32)8;
        u32 dynAddr = align4(off);
        u32 dynEnd = dynAddr + dynCount * (u32)8;
        u32 dataBase = alignPage(dynEnd);
        u32 bssBase = align4(dataBase + data.count());

        Array* textOut = Elf32.copyBytes(text);
        Array* dataOut = Elf32.copyBytes(data);
        Array* dynRel = new Array();
        if (!applyRelocs(relocs, syms, textOut, dataOut, textBase, dataBase, bssBase,
                         imports, veneerBase, dynRel))
            return (Array*)0;
        // Each veneer's word is resolved by the loader against its symbol.
        for (u32 i = (u32)0; i < imports.count(); i = i + (u32)1)
            dynRel.add((Object*)Elf32DynRel.with(
                veneerBase + i * (u32)VENEER_SZ + (u32)4,
                (u32)R_ARM_GLOB_DAT, (String*)imports.get(i)));
        if (dynRel.count() != nDynRel)
            {
            _failed = true;
            _why = String.withCString(
                "relocation count moved between the sizing and emitting passes");
            return (Array*)0;
            }

        // ── Emit ─────────────────────────────────────────────────────────
        _out = new Array();
        byte((u32)$7F);
        byte((u32)'E');
        byte((u32)'L');
        byte((u32)'F');
        byte((u32)1);
        byte((u32)1);
        byte((u32)1);
        for (u32 i = (u32)0; i < (u32)9; i = i + (u32)1)
            byte((u32)0);
        half((u32)3);
        half((u32)40);
        word((u32)1);         // ET_DYN, EM_ARM, version
        word((u32)0);         // e_entry — the loader finds `main`
        word((u32)52);        // e_phoff
        word((u32)0);         // e_shoff — patched below
        word((u32)$05000000); // e_flags: EABI 5
        half((u32)52);
        half((u32)32);
        half((u32)3); // ehsize, phentsize, phnum
        half((u32)40);
        half((u32)0);
        half((u32)0); // shentsize/shnum/shstrndx — patched

        phdr32((u32)1, textBase, dynEnd - textBase, dynEnd - textBase, (u32)5,
               (u32)ELF32_PAGE);
        phdr32((u32)1, dataBase, data.count(), bssSize + data.count(), (u32)6,
               (u32)ELF32_PAGE);
        phdr32((u32)2, dynAddr, dynCount * (u32)8, dynCount * (u32)8, (u32)6, (u32)4);

        padTo(textBase);
        bytesFrom(textOut);
        // The veneers, two words each: `ldr pc, [pc, #-4]` reads the word that
        // follows it (pc reads as the instruction's address plus eight), and
        // the loader writes the resolved address into that word.
        padTo(veneerBase);
        for (u32 i = (u32)0; i < imports.count(); i = i + (u32)1)
            {
            word((u32)$E51FF004);
            word((u32)0);
            }

        padTo(hashAddr);
        word(nbucket);
        word(symCount); // nchain
        word(symCount > (u32)1 ? (u32)1 : (u32)0);
        for (u32 i = (u32)0; i < symCount; i = i + (u32)1)
            word(i + (u32)1 < symCount ? i + (u32)1 : (u32)0);

        padTo(symAddr);
        word((u32)0);
        word((u32)0);
        word((u32)0);
        word((u32)0); // the null entry
        for (u32 i = (u32)0; i < dyn.count(); i = i + (u32)1)
            {
            AsmSymbol* sy = (AsmSymbol*)dyn.get(i);
            word(((Number*)nameOff.get(i)).asU32());
            word(Elf32.addressOf(sy, textBase, dataBase, bssBase));
            word(sy.size());
            byte(((u32)1 << (u32)4) | (sy.isFunction() ? (u32)2 : (u32)1)); // GLOBAL|FUNC/OBJECT
            byte(sy.hidden() ? (u32)2 : (u32)0);                            // STV_HIDDEN
            half(sy.section() == (u32)0 ? (u32)0 : (u32)1);
            }

        padTo(strAddr);
        for (u32 i = (u32)0; i < dynstr.count(); i = i + (u32)1)
            byte(((Number*)dynstr.get(i)).asU32());

        padTo(relAddr);
        for (u32 i = (u32)0; i < dynRel.count(); i = i + (u32)1)
            {
            Elf32DynRel* r = (Elf32DynRel*)dynRel.get(i);
            word(r.addr());
            if (r.type() == (u32)R_ARM_RELATIVE)
                {
                word((u32)R_ARM_RELATIVE);
                continue;
                }
            u32 si = (u32)0;
            for (u32 k = (u32)0; k < dyn.count(); k = k + (u32)1)
                if (((AsmSymbol*)dyn.get(k)).name().equals(r.symbol()))
                    {
                    si = k + (u32)1;
                    k = dyn.count();
                    }
            word((si << (u32)8) | r.type());
            }

        padTo(dynAddr);
        // DT_NEEDED first: the loader has to have the library mapped before it
        // can resolve a name into it.
        for (u32 i = (u32)0; i < needed.count(); i = i + (u32)1)
            {
            word((u32)DT_NEEDED_T);
            word(((Number*)neededOff.get(i)).asU32());
            }
        if (hasSoname)
            {
            word((u32)DT_SONAME_T);
            word(sonameOff);
            }
        word((u32)DT_HASH_T);
        word(hashAddr);
        word((u32)DT_SYMTAB_T);
        word(symAddr);
        word((u32)DT_STRTAB_T);
        word(strAddr);
        word((u32)DT_STRSZ_T);
        word(dynstr.count());
        word((u32)DT_SYMENT_T);
        word((u32)16);
        word((u32)DT_REL_T);
        word(relAddr);
        word((u32)DT_RELSZ_T);
        word(nDynRel * (u32)8);
        word((u32)DT_RELENT_T);
        word((u32)8);
        word((u32)0);
        word((u32)0); // DT_NULL

        padTo(dataBase);
        bytesFrom(dataOut);

        emitSections(textBase, textSize, hashAddr, nbucket, symCount, symAddr,
                     strAddr, dynstr.count(), relAddr, nDynRel, dynAddr, dynCount,
                     dataBase, data.count(), bssBase, bssSize, iface);
        return _out;
        }

    // The loader never reads section headers — it works from the program
    // headers alone — but every ordinary tool does: `#import <lib>` finds
    // `.xtc.iface` through them, and so do readelf -S and nm -D, which report
    // NOTHING for a section-less image. Everything here is appended AFTER the
    // mapped segments and is in no PT_LOAD, so it cannot perturb a layout the
    // loader already agreed with.
    void emitSections(u32 textBase, u32 textSize, u32 hashAddr, u32 nbucket,
                      u32 symCount, u32 symAddr, u32 strAddr, u32 strSize,
                      u32 relAddr, u32 nDynRel, u32 dynAddr, u32 dynCount,
                      u32 dataBase, u32 dataSize, u32 bssBase, u32 bssSize,
                      Array* iface)
        {
        u32 ifaceOff = (u32)0;
        u32 ifaceLen = iface == (Array*)0 ? (u32)0 : iface.count();
        if (ifaceLen > (u32)0)
            {
            while ((_out.count() & (u32)3) != (u32)0)
                byte((u32)0);
            ifaceOff = _out.count();
            bytesFrom(iface);
            byte((u32)0); // NUL-terminated, as the .incbin form was
            ifaceLen = _out.count() - ifaceOff;
            }
        Array* names = new Array();
        names.add((Object*)String.withCString(""));
        names.add((Object*)String.withCString(".text"));
        names.add((Object*)String.withCString(".hash"));
        names.add((Object*)String.withCString(".dynsym"));
        names.add((Object*)String.withCString(".dynstr"));
        names.add((Object*)String.withCString(".rel.dyn"));
        names.add((Object*)String.withCString(".dynamic"));
        names.add((Object*)String.withCString(".data"));
        names.add((Object*)String.withCString(".bss"));
        names.add((Object*)String.withCString(".xtc.iface"));
        names.add((Object*)String.withCString(".shstrtab"));
        Array* shstr = new Array();
        Array* nameOff = new Array();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            nameOff.add((Object*)Number.with(shstr.count()));
            Elf32.strInto(shstr, (String*)names.get(i));
            }
        while ((_out.count() & (u32)3) != (u32)0)
            byte((u32)0);
        u32 shstrOff = _out.count();
        bytesFrom(shstr);
        while ((_out.count() & (u32)3) != (u32)0)
            byte((u32)0);
        u32 shoff = _out.count();

        shdr32(nameOff, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0);
        shdr32(nameOff, (u32)1, (u32)1, (u32)6, textBase, textBase, textSize, (u32)0, (u32)0, (u32)4);
        shdr32e(nameOff, (u32)2, (u32)5, (u32)2, hashAddr, hashAddr,
                (u32)4 * ((u32)2 + nbucket + symCount), (u32)3, (u32)0, (u32)4, (u32)4);
        shdr32e(nameOff, (u32)3, (u32)11, (u32)2, symAddr, symAddr, symCount * (u32)16,
                (u32)4, (u32)1, (u32)4, (u32)16);
        shdr32(nameOff, (u32)4, (u32)3, (u32)2, strAddr, strAddr, strSize, (u32)0, (u32)0, (u32)1);
        shdr32e(nameOff, (u32)5, (u32)9, (u32)2, relAddr, relAddr, nDynRel * (u32)8,
                (u32)3, (u32)0, (u32)4, (u32)8);
        shdr32e(nameOff, (u32)6, (u32)6, (u32)3, dynAddr, dynAddr, dynCount * (u32)8,
                (u32)4, (u32)0, (u32)4, (u32)8);
        shdr32(nameOff, (u32)7, (u32)1, (u32)3, dataBase, dataBase, dataSize, (u32)0, (u32)0, (u32)4);
        shdr32(nameOff, (u32)8, (u32)8, (u32)3, bssBase, bssBase, bssSize, (u32)0, (u32)0, (u32)4);
        // NOT SHF_ALLOC: the interface is build-time metadata, read from the
        // FILE by the compiler and never mapped at run time.
        shdr32(nameOff, (u32)9, (u32)1, (u32)0, (u32)0, ifaceOff, ifaceLen, (u32)0, (u32)0, (u32)4);
        shdr32(nameOff, (u32)10, (u32)3, (u32)0, (u32)0, shstrOff, shstr.count(), (u32)0, (u32)0, (u32)4);

        patchWord32((u32)32, shoff);
        _out.set((u32)46, (Object*)Number.with((u32)40));
        _out.set((u32)48, (Object*)Number.with(names.count() & (u32)$FF));
        _out.set((u32)50, (Object*)Number.with((names.count() - (u32)1) & (u32)$FF));
        }

    void phdr32(u32 kind, u32 vaddr, u32 filesz, u32 memsz, u32 flags, u32 palign)
        {
        word(kind);
        word(vaddr); // p_offset — mapped 1:1
        word(vaddr);
        word(vaddr);
        word(filesz);
        word(memsz);
        word(flags);
        word(palign);
        }

    void shdr32(Array* nameOff, u32 ni, u32 kind, u32 flags, u32 addr, u32 offset,
                u32 size, u32 link, u32 info, u32 align)
        {
        shdr32e(nameOff, ni, kind, flags, addr, offset, size, link, info, align, (u32)0);
        }

    void shdr32e(Array* nameOff, u32 ni, u32 kind, u32 flags, u32 addr, u32 offset,
                 u32 size, u32 link, u32 info, u32 align, u32 entsize)
        {
        word(((Number*)nameOff.get(ni)).asU32());
        word(kind);
        word(flags);
        word(addr);
        word(offset);
        word(size);
        word(link);
        word(info);
        word(align);
        word(entsize);
        }

    void patchWord32(u32 at, u32 v)
        {
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            _out.set(at + i, (Object*)Number.with((v >> ((u32)8 * i)) & (u32)$FF));
        }

    // Resolve every relocation into the image, recording the ones the LOADER
    // must finish. REL semantics throughout: the addend is in the word.
    bool applyRelocs(Array* relocs, Array* syms, Array* textOut, Array* dataOut,
                     u32 textBase, u32 dataBase, u32 bssBase, Array* imports,
                     u32 veneerBase, Array* dynRel)
        {
        for (u32 i = (u32)0; i < relocs.count(); i = i + (u32)1)
            {
            AsmReloc* r = (AsmReloc*)relocs.get(i);
            AsmSymbol* sy = Elf32.findSym(syms, r.symbol());
            Array* sec = r.section() == (u32)1 ? textOut : dataOut;
            u32 base = r.section() == (u32)1 ? textBase : dataBase;
            u32 target = (u32)0;
            if (sy == (AsmSymbol*)0 || sy.section() == (u32)0)
                {
                u32 imp = Elf32.indexOfString(imports, r.symbol());
                if (imp == (u32)$FFFF_FFFF)
                    {
                    _failed = true;
                    _why = String.withCString("undefined symbol: ").appending(r.symbol());
                    return false;
                    }
                if (r.type() == (u32)R_ARM_CALL)
                    {
                    target = veneerBase + imp * (u32)VENEER_SZ;
                    }
                else
                    {
                    // A DATA reference to an import is left to the loader,
                    // against the symbol itself.
                    Elf32.patchWord(sec, r.offset(), (u32)0, false);
                    dynRel.add((Object*)Elf32DynRel.with(base + r.offset(),
                                                         (u32)R_ARM_GLOB_DAT, r.symbol()));
                    continue;
                    }
                }
            else
                {
                target = Elf32.addressOf(sy, textBase, dataBase, bssBase);
                }
            if (r.type() == (u32)R_ARM_CALL)
                {
                u32 at = base + r.offset();
                i32 delta = ((i32)target - (i32)at - (i32)8) >> (i32)2;
                Elf32.patchWord(sec, r.offset(), (u32)delta & (u32)$FFFFFF, true);
                continue;
                }
            // The addend is IN the word: `.word sym+16` holds 16 and means
            // sym+16, so the address is ADDED to what is already there.
            Elf32.patchWord(sec, r.offset(),
                            target + Elf32.readWord(sec, r.offset()), false);
            dynRel.add((Object*)Elf32DynRel.with(base + r.offset(),
                                                 (u32)R_ARM_RELATIVE, r.symbol()));
            }
        return true;
        }

    static u32 alignPage(u32 v)
        {
        return (v + (u32)ELF32_PAGE - (u32)1) & ~((u32)ELF32_PAGE - (u32)1);
        }

    static Array* copyBytes(Array* a)
        {
        Array* o = new Array();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            o.add(a.get(i));
        return o;
        }

    static void strInto(Array* blob, String* s)
        {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            blob.add((Object*)Number.with((u32)s.byteAt(i)));
        blob.add((Object*)Number.with((u32)0));
        }

    static AsmSymbol* findSym(Array* syms, String* name)
        {
        for (u32 i = (u32)0; i < syms.count(); i = i + (u32)1)
            {
            AsmSymbol* s = (AsmSymbol*)syms.get(i);
            if (s.name() != (String*)0 && s.name().equals(name))
                return s;
            }
        return (AsmSymbol*)0;
        }

    static bool hasString(Array* a, String* s)
        {
        return Elf32.indexOfString(a, s) != (u32)$FFFF_FFFF;
        }

    static u32 indexOfString(Array* a, String* s)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(s))
                return i;
        return (u32)$FFFF_FFFF;
        }

    // The runtime address of a symbol, relative to the image's own base.
    static u32 addressOf(AsmSymbol* s, u32 textBase, u32 dataBase, u32 bssBase)
        {
        if (s.section() == (u32)1)
            return textBase + s.value();
        if (s.section() == (u32)2)
            return dataBase + s.value();
        if (s.section() == (u32)3)
            return bssBase + s.value();
        return (u32)0;
        }

    static u32 readWord(Array* sec, u32 at)
        {
        if (at + (u32)4 > sec.count())
            return (u32)0;
        return ((Number*)sec.get(at)).asU32() | (((Number*)sec.get(at + (u32)1)).asU32() << (u32)8) | (((Number*)sec.get(at + (u32)2)).asU32() << (u32)16) | (((Number*)sec.get(at + (u32)3)).asU32() << (u32)24);
        }

    // `keepTop` preserves the condition and opcode bits a branch's displacement
    // shares its word with.
    static void patchWord(Array* sec, u32 at, u32 value, bool keepTop)
        {
        if (at + (u32)4 > sec.count())
            return;
        u32 old = Elf32.readWord(sec, at);
        u32 w = keepTop ? ((old & (u32)$FF000000) | (value & (u32)$FFFFFF)) : value;
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            sec.set(at + i, (Object*)Number.with((w >> ((u32)8 * i)) & (u32)$FF));
        }

    Array* write(Array* text, Array* data, Array* syms, Array* relocs)
        {
        _out = new Array();

        // Symbols are ordered locals-first: the ELF symbol table requires it,
        // and `sh_info` on .symtab is the index of the first global.
        // An UNDEFINED symbol is global by definition: it is a reference the
        // linker has to satisfy from another object, and a local one it would
        // simply refuse to look for. (This is what a `bl memcpy` produces —
        // the assembler saw the name and nothing else.)
        for (u32 i = (u32)0; i < syms.count(); i = i + (u32)1)
            {
            AsmSymbol* s = (AsmSymbol*)syms.get(i);
            if (s.section() == (u32)0)
                s.setGlobal();
            }
        Array* ordered = new Array();
        for (u32 i = (u32)0; i < syms.count(); i = i + (u32)1)
            {
            AsmSymbol* s = (AsmSymbol*)syms.get(i);
            if (!s.isGlobal())
                ordered.add((Object*)s);
            }
        u32 firstGlobal = ordered.count() + (u32)1; // +1 for the null entry
        for (u32 i = (u32)0; i < syms.count(); i = i + (u32)1)
            {
            AsmSymbol* s = (AsmSymbol*)syms.get(i);
            if (s.isGlobal())
                ordered.add((Object*)s);
            }

        Array* textRel = new Array();
        Array* dataRel = new Array();
        for (u32 i = (u32)0; i < relocs.count(); i = i + (u32)1)
            {
            AsmReloc* r = (AsmReloc*)relocs.get(i);
            if (r.section() == (u32)1)
                textRel.add((Object*)r);
            else
                dataRel.add((Object*)r);
            }

        strTableInit();
        Map* symIndex = new Map();
        for (u32 i = (u32)0; i < ordered.count(); i = i + (u32)1)
            {
            AsmSymbol* s = (AsmSymbol*)ordered.get(i);
            strAdd(s.name());
            symIndex.set((Hashable*)s.name(), (Object*)Number.with(i + (u32)1));
            }

        // Section names live in their own table, which is what `e_shstrndx`
        // points at.
        Array* shNames = new Array();
        shNames.add((Object*)String.withCString(""));
        shNames.add((Object*)String.withCString(".text"));
        shNames.add((Object*)String.withCString(".data"));
        shNames.add((Object*)String.withCString(".bss"));
        if (textRel.count() > (u32)0)
            shNames.add((Object*)String.withCString(".rel.text"));
        if (dataRel.count() > (u32)0)
            shNames.add((Object*)String.withCString(".rel.data"));
        shNames.add((Object*)String.withCString(".symtab"));
        shNames.add((Object*)String.withCString(".strtab"));
        shNames.add((Object*)String.withCString(".shstrtab"));

        Array* shstr = new Array();
        Map* shstrOff = new Map();
        shstr.add((Object*)Number.with((u32)0));
        for (u32 i = (u32)1; i < shNames.count(); i = i + (u32)1)
            {
            String* n = (String*)shNames.get(i);
            shstrOff.set((Hashable*)n, (Object*)Number.with(shstr.count()));
            for (u32 k = (u32)0; k < n.byteLength(); k = k + (u32)1)
                shstr.add((Object*)Number.with((u32)n.byteAt(k)));
            shstr.add((Object*)Number.with((u32)0));
            }

        // ── Offsets. The header is 52 bytes; everything else follows in the
        // order it is written, each aligned to four.
        u32 off = (u32)52;
        u32 textOff = off;
        off = Elf32.align4(off + text.count());
        u32 dataOff = off;
        off = Elf32.align4(off + data.count());
        u32 textRelOff = off;
        off = Elf32.align4(off + textRel.count() * (u32)8);
        u32 dataRelOff = off;
        off = Elf32.align4(off + dataRel.count() * (u32)8);
        u32 symOff = off;
        off = Elf32.align4(off + (ordered.count() + (u32)1) * (u32)16);
        u32 strOff = off;
        off = Elf32.align4(off + _strBytes.count());
        u32 shstrOffset = off;
        off = Elf32.align4(off + shstr.count());
        u32 shOff = off;

        // Section indices, in the order the headers are written.
        u32 idx = (u32)1;
        u32 textIdx = idx;
        idx = idx + (u32)1;
        u32 dataIdx = idx;
        idx = idx + (u32)1;
        u32 bssIdx = idx;
        idx = idx + (u32)1;
        u32 textRelIdx = (u32)0;
        u32 dataRelIdx = (u32)0;
        if (textRel.count() > (u32)0)
            {
            textRelIdx = idx;
            idx = idx + (u32)1;
            }
        if (dataRel.count() > (u32)0)
            {
            dataRelIdx = idx;
            idx = idx + (u32)1;
            }
        u32 symIdx = idx;
        idx = idx + (u32)1;
        u32 strIdx = idx;
        idx = idx + (u32)1;
        u32 shstrIdx = idx;
        idx = idx + (u32)1;
        u32 shCount = idx;

        // ── ELF header ───────────────────────────────────────────────────
        byte((u32)$7F);
        byte((u32)'E');
        byte((u32)'L');
        byte((u32)'F');
        byte((u32)1); // EI_CLASS  = ELFCLASS32
        byte((u32)1); // EI_DATA   = little-endian
        byte((u32)1); // EI_VERSION
        byte((u32)0); // EI_OSABI  = System V
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            byte((u32)0);
        half((u32)1);  // e_type    = ET_REL
        half((u32)40); // e_machine = EM_ARM
        word((u32)1);  // e_version
        word((u32)0);  // e_entry   — none, this is an object
        word((u32)0);  // e_phoff
        word(shOff);
        // EABI version 5, and the soft-float flag the arm9 path builds with.
        word((u32)$05000000); // e_flags
        half((u32)52);        // e_ehsize
        half((u32)0);
        half((u32)0);  // e_phentsize / e_phnum
        half((u32)40); // e_shentsize
        half(shCount);
        half(shstrIdx);

        padTo(textOff);
        bytesFrom(text);
        padTo(dataOff);
        bytesFrom(data);
        padTo(textRelOff);
        writeRelocs(textRel, symIndex);
        padTo(dataRelOff);
        writeRelocs(dataRel, symIndex);
        padTo(symOff);
        writeSymbols(ordered, textIdx, dataIdx);
        padTo(strOff);
        bytesFrom(_strBytes);
        padTo(shstrOffset);
        bytesFrom(shstr);
        padTo(shOff);

        // ── Section headers ──────────────────────────────────────────────
        sectionHeader((u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0);
        // .text — allocated, executable.
        sectionHeader(shstrIndexOf(shstrOff, ".text"), (u32)1, (u32)6, (u32)0,
                      textOff, text.count(), (u32)0, (u32)0, (u32)4);
        // .data — allocated, writable.
        sectionHeader(shstrIndexOf(shstrOff, ".data"), (u32)1, (u32)3, (u32)0,
                      dataOff, data.count(), (u32)0, (u32)0, (u32)4);
        // .bss — allocated, writable, occupies no file space.
        sectionHeader(shstrIndexOf(shstrOff, ".bss"), (u32)8, (u32)3, (u32)0,
                      dataOff + data.count(), (u32)0, (u32)0, (u32)0, (u32)4);
        if (textRel.count() > (u32)0)
            sectionHeader(shstrIndexOf(shstrOff, ".rel.text"), (u32)9, (u32)0, (u32)0,
                          textRelOff, textRel.count() * (u32)8, symIdx, textIdx, (u32)4);
        if (dataRel.count() > (u32)0)
            sectionHeader(shstrIndexOf(shstrOff, ".rel.data"), (u32)9, (u32)0, (u32)0,
                          dataRelOff, dataRel.count() * (u32)8, symIdx, dataIdx, (u32)4);
        // .symtab — sh_link is the string table, sh_info the first global.
        sectionHeader(shstrIndexOf(shstrOff, ".symtab"), (u32)2, (u32)0, (u32)0,
                      symOff, (ordered.count() + (u32)1) * (u32)16, strIdx, firstGlobal, (u32)4);
        sectionHeader(shstrIndexOf(shstrOff, ".strtab"), (u32)3, (u32)0, (u32)0,
                      strOff, _strBytes.count(), (u32)0, (u32)0, (u32)1);
        sectionHeader(shstrIndexOf(shstrOff, ".shstrtab"), (u32)3, (u32)0, (u32)0,
                      shstrOffset, shstr.count(), (u32)0, (u32)0, (u32)1);
        return _out;
        }

    u32 shstrIndexOf(Map* table, string name)
        {
        Object* o = table.get((Hashable*)String.withCString(name));
        return o == 0 ? (u32)0 : ((Number*)o).asU32();
        }

    void sectionHeader(u32 name, u32 kind, u32 flags, u32 addr,
                       u32 offset, u32 size, u32 link, u32 info, u32 addralign)
        {
        word(name);
        word(kind);
        word(flags);
        word(addr);
        word(offset);
        word(size);
        word(link);
        word(info);
        word(addralign);
        // sh_entsize: a symbol is 16 bytes, a REL relocation 8.
        word(kind == (u32)2 ? (u32)16 : (kind == (u32)9 ? (u32)8 : (u32)0));
        }

    void writeRelocs(Array* relocs, Map* symIndex)
        {
        for (u32 i = (u32)0; i < relocs.count(); i = i + (u32)1)
            {
            AsmReloc* r = (AsmReloc*)relocs.get(i);
            Object* si = symIndex.get((Hashable*)r.symbol());
            u32 n = si == 0 ? (u32)0 : ((Number*)si).asU32();
            word(r.offset());
            word((n << 8) | (r.type() & (u32)$FF));
            }
        }

    void writeSymbols(Array* ordered, u32 textIdx, u32 dataIdx)
        {
        // The null symbol. Index 0 means "no symbol" everywhere else.
        word((u32)0);
        word((u32)0);
        word((u32)0);
        word((u32)0);
        for (u32 i = (u32)0; i < ordered.count(); i = i + (u32)1)
            {
            AsmSymbol* s = (AsmSymbol*)ordered.get(i);
            u32 shndx = (u32)0; // SHN_UNDEF
            u32 value = s.value();
            u32 size = s.size();
            if (s.section() == (u32)1)
                shndx = textIdx;
            else if (s.section() == (u32)2)
                shndx = dataIdx;
            else if (s.section() == (u32)3)
                {
                // COMMON: the value is the ALIGNMENT and the size the storage,
                // which is the one place those two fields swap meaning.
                shndx = (u32)$FFF2;
                }
            u32 bind = s.isGlobal() ? (u32)1 : (u32)0; // GLOBAL / LOCAL
            if (s.section() == (u32)3)
                bind = (u32)1;
            u32 type = s.isFunction() ? (u32)2 : (u32)0; // FUNC / NOTYPE
            if (s.section() == (u32)3)
                type = (u32)1;                        // OBJECT
            u32 other = s.hidden() ? (u32)2 : (u32)0; // STV_HIDDEN
            word(strAdd(s.name()));
            word(value);
            word(size);
            byte((bind << 4) | type);
            byte(other);
            half(shndx);
            }
        }
    }
