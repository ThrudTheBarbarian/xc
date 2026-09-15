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
// never becomes a dynamic relocation. Exactly two kinds survive to load time:
// R_AARCH64_RELATIVE for each `.quad <symbol>` — a vtable word, an absolute
// address the loader must bias — and R_AARCH64_GLOB_DAT for each symbol
// imported from bionic, reached from a 16-byte adrp/ldr/br thunk so the back
// end's direct `bl` needs no rewriting.
//
// As in the other writers, addresses are kept as 32-bit FILE OFFSETS and the
// high half of every 64-bit field is written as zero. Nothing here is mapped
// above 4 GB before the loader applies its bias, and the bias is added at run
// time, not by us.

#import "Foundation.xc"
#import "Arm64Asm.xc"

// 16 KB, not 4. Android 15 runs on devices with 16 KB pages and will not map a
// 4 KB-aligned segment; 16 KB is accepted on 4 KB devices too, so there is one
// right answer and this is it.
#define AELF_PAGE $4000
#define AEHDR_SZ 64
#define APHDR_SZ 56
#define ASHDR_SZ 64
#define ASYM_SZ 24
#define ARELA_SZ 24
#define ADYN_SZ 16
#define ATHUNK_SZ 16

class ElfArm64
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
    void p64(u32 v)
        {
        p32(v);
        p32((u32)0);
        }
    void padTo(u32 off)
        {
        while (_out.count() < off)
            p8((u32)0);
        }

    static u32 roundUpTo(u32 v, u32 a)
        {
        return (v + a - (u32)1) & ~(a - (u32)1);
        }

    // Trailing zeros need not be stored: a PT_LOAD whose p_memsz exceeds its
    // p_filesz is zero-filled by the kernel, which is what .bss and a
    // zero-initialised array are.
    static u32 fileSizeOf(Array* d)
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
    static u32 rdw(Array* b, u32 o)
        {
        return ((Number*)b.get(o)).asU32() | (((Number*)b.get(o + (u32)1)).asU32() << (u32)8) | (((Number*)b.get(o + (u32)2)).asU32() << (u32)16) | (((Number*)b.get(o + (u32)3)).asU32() << (u32)24);
        }

    static void wrw(Array* b, u32 o, u32 w)
        {
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            b.set(o + i, (Object*)Number.withU32((w >> ((u32)8 * i)) & (u32)$FF));
        }

    // bl / b: imm26 = (target - pc) >> 2, signed, ±128 MB.
    void patchBranch26(Array* t, u32 off, u32 target, u32 site, String* sym)
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
    void patchAdrp(Array* t, u32 off, u32 target, u32 site, String* sym)
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
    void patchLo12(Array* t, u32 off, u32 target, u32 scale, String* sym)
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
    void image(Array* textIn, Array* dataIn, Map* symbols, Array* dataSyms,
               Array* exportsIn, Array* fixups, String* soname, Array* needed,
               String* entry, u32 modInitLength)
        {
        bool isExec = entry != (String*)0 && entry.byteLength() > (u32)0;
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
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)fixups.get(i);
            if (symbols.get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            bool isGot = f.kind() == (u32)FIXUP_GOTPAGE21 || f.kind() == (u32)FIXUP_GOTPAGEOFF12;
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

        // ── 2. exports ───────────────────────────────────────────────────
        Array* exports = new Array();
        for (u32 i = (u32)0; i < exportsIn.count(); i = i + (u32)1)
            {
            String* n = (String*)exportsIn.get(i);
            if (symbols.get((Hashable*)n) != (Object*)0 && !inArray(exports, n))
                exports.add((Object*)n);
            }

        // ── 3. sizes, then addresses ─────────────────────────────────────
        Array* text = new Array();
        for (u32 i = (u32)0; i < textIn.count(); i = i + (u32)1)
            text.add(textIn.get(i));
        Array* data = new Array();
        for (u32 i = (u32)0; i < dataIn.count(); i = i + (u32)1)
            data.add(dataIn.get(i));

        u32 thunkOff = roundUpTo(text.count(), (u32)16);
        // nop padding
        while (text.count() < thunkOff)
            {
            wrwAppend(text, (u32)$D503201F);
            }

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
            internStr(dynstr, strOff, (String*)symOrder.get(i));
        u32 sonameOff = (u32)0;
        if (!isExec && soname != (String*)0 && soname.byteLength() > (u32)0)
            sonameOff = internStr(dynstr, strOff, soname);
        Array* neededOff = new Array();
        if (needed != (Array*)0)
            for (u32 i = (u32)0; i < needed.count(); i = i + (u32)1)
                neededOff.add((Object*)Number.withU32(
                    internStr(dynstr, strOff, (String*)needed.get(i))));

        u32 nbucket = nsym < (u32)4 ? (u32)1 : nsym / (u32)4 + (u32)1;
        u32 hashSz = ((u32)2 + nbucket + nsym) * (u32)4;
        // The constructor array cannot be longer than the data it sits in.
        u32 miLen = modInitLength <= dataIn.count() ? modInitLength : (u32)0;
        u32 nDyn = (u32)8 + (isExec ? (u32)0 : (u32)1) + neededOff.count() + (u32)1 + (miLen > (u32)0 ? (u32)2 : (u32)0);

        // One RELATIVE per `.quad <symbol>` and one GLOB_DAT per import.
        Array* absFixups = new Array();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)fixups.get(i);
            if (f.kind() == (u32)FIXUP_POINTER64)
                absFixups.add((Object*)f);
            }
        u32 nRela = absFixups.count() + imports.count();

        u32 nphdr = isExec ? (u32)7 : (u32)5;
        u32 interpOff = roundUpTo((u32)AEHDR_SZ + nphdr * (u32)APHDR_SZ, (u32)8);
        u32 interpSz = isExec ? (u32)21 : (u32)0; // "/system/bin/linker64" + NUL
        u32 roOff = roundUpTo(interpOff + interpSz, (u32)8);
        u32 symOff = roOff;
        u32 strOffB = symOff + nsym * (u32)ASYM_SZ;
        u32 hashOff = roundUpTo(strOffB + dynstr.count(), (u32)8);
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
        u32 rwEnd = dataAddr + data.count();

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
                if (f.offset() + (u32)8 > data.count())
                    {
                    failWith(String.withCString("pointer64 fixup past end of data:"), f.symbol());
                    return;
                    }
                // Written with the link-time address; the RELATIVE relocation
                // makes the loader add the load bias on top.
                for (u32 b = (u32)0; b < (u32)8; b = b + (u32)1)
                    data.set(f.offset() + b,
                             (Object*)Number.withU32(b < (u32)4
                                                         ? ((target >> ((u32)8 * b)) & (u32)$FF)
                                                         : (u32)0));
                continue;
                }
            if (f.offset() + (u32)4 > text.count())
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
        u32 shoffField = _out.count();
        p64((u32)0); // e_shoff — patched below
        p32((u32)0); // e_flags
        p16((u32)AEHDR_SZ);
        p16((u32)APHDR_SZ);
        p16(nphdr);
        p16((u32)ASHDR_SZ);
        p16((u32)4); // e_shnum
        p16((u32)3); // e_shstrndx

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

        if (isExec)
            {
            padTo(interpOff);
            String* interp = String.withCString("/system/bin/linker64");
            for (u32 i = (u32)0; i < interp.byteLength(); i = i + (u32)1)
                p8((u32)interp.byteAt(i));
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
            p32(isNull ? (u32)0 : lookupStr(strOff, n));
            p8(isNull ? (u32)0 : ((u32)1 << (u32)4) | (inData ? (u32)1 : (u32)2));
            p8((u32)0);
            p16((isNull || off == (Object*)0) ? (u32)0 : (u32)1); // st_shndx
            p64(off != (Object*)0
                    ? (inData ? dataAddr : textAddr) + ((Number*)off).asU32()
                    : (u32)0);
            p64((u32)0); // st_size
            }
        padTo(strOffB);
        for (u32 i = (u32)0; i < dynstr.count(); i = i + (u32)1)
            p8(((Number*)dynstr.get(i)).asU32());

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
        // R_AARCH64_RELATIVE
        for (u32 i = (u32)0; i < absFixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)absFixups.get(i);
            Object* off = symbols.get((Hashable*)f.symbol());
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
        for (u32 i = (u32)0; i < text.count(); i = i + (u32)1)
            p8(((Number*)text.get(i)).asU32());
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
        dyn((u32)4, hashOff);               // DT_HASH
        dyn((u32)5, strOffB);               // DT_STRTAB
        dyn((u32)6, symOff);                // DT_SYMTAB
        dyn((u32)10, dynstr.count());       // DT_STRSZ
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
            dyn((u32)25, dataAddr + (data.count() - miLen)); // DT_INIT_ARRAY
            dyn((u32)27, miLen);                             // DT_INIT_ARRAYSZ
            }
        dyn((u32)0, (u32)0); // DT_NULL

        padTo(dataAddr);
        for (u32 i = (u32)0; i < dataFileSz; i = i + (u32)1)
            p8(((Number*)data.get(i)).asU32());

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
        Array* shstr = new Array();
        Map* shOff = new Map();
        shstr.add((Object*)Number.withU32((u32)0));
        u32 nDynamic = internStr(shstr, shOff, String.withCString(".dynamic"));
        u32 nDynstr = internStr(shstr, shOff, String.withCString(".dynstr"));
        u32 nShstrtab = internStr(shstr, shOff, String.withCString(".shstrtab"));
        u32 shstrOff = _out.count();
        for (u32 i = (u32)0; i < shstr.count(); i = i + (u32)1)
            p8(((Number*)shstr.get(i)).asU32());
        while (_out.count() % (u32)8 != (u32)0)
            p8((u32)0);
        u32 shoff = _out.count();
        shdr((u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0);
        // .dynamic — sh_link names [2], where its strings live.
        shdr(nDynamic, (u32)6, (u32)3, dynOff, dynOff, nDyn * (u32)ADYN_SZ,
             (u32)2, (u32)8, (u32)ADYN_SZ);
        shdr(nDynstr, (u32)3, (u32)2, strOffB, strOffB, dynstr.count(), (u32)0, (u32)1, (u32)0);
        shdr(nShstrtab, (u32)3, (u32)0, (u32)0, shstrOff, shstr.count(), (u32)0, (u32)1, (u32)0);

        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            _out.set(shoffField + i,
                     (Object*)Number.withU32(i < (u32)4
                                                 ? ((shoff >> ((u32)8 * i)) & (u32)$FF)
                                                 : (u32)0));
        }

    // ── small emitters ───────────────────────────────────────────────────
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

    static void wrwAppend(Array* b, u32 w)
        {
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            b.add((Object*)Number.withU32((w >> ((u32)8 * i)) & (u32)$FF));
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
    }
