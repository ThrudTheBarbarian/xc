#import "XTPEWriter.h"
#import "XTArArchive.h"

// PE/COFF constants, defined in-house so the writer is host-independent (the
// same reason XTMachOWriter defines its own Mach-O constants rather than
// including <mach-o/loader.h>).
enum
    {
    PE_MACHINE_AMD64 = 0x8664,
    PE_CHAR_EXECUTABLE = 0x0002,
    PE_CHAR_LARGE_ADDRESS = 0x0020,
    PE_MAGIC_PE32PLUS = 0x20B,
    PE_SUBSYSTEM_CUI = 3, // console
    // Section characteristics.
    PE_SCN_CODE = 0x00000020,
    PE_SCN_INITIALIZED_DATA = 0x00000040,
    PE_SCN_UNINIT_DATA = 0x00000080,
    PE_SCN_MEM_DISCARDABLE = 0x02000000,
    PE_SCN_MEM_EXECUTE = 0x20000000,
    PE_SCN_MEM_READ = 0x40000000,
    PE_SCN_MEM_WRITE = 0x80000000,

    PE_FILE_ALIGN = 0x200,
    PE_SECT_ALIGN = 0x1000,
    PE_NUM_DIRECTORIES = 16,
    PE_DIR_IMPORT = 1,
    PE_DIR_IAT = 12,
    PE_OPT_HDR_SIZE = 240, // PE32+ optional header incl. 16 directories
    PE_SECT_HDR_SIZE = 40,
    PE_THUNK_SZ = 6, // ff 25 <rel32>  =  jmp qword ptr [rip + IAT]
    };

// A default ImageBase with DYNAMIC_BASE left OFF, so the loader honours it and
// no .reloc section is needed. That is the simplest thing that is correct; the
// cost is no ASLR, which is a hardening property rather than a correctness one.
#define PE_IMAGE_BASE 0x140000000ull

static void p8(NSMutableData* d, uint8_t v)
    {
    [d appendBytes:&v length:1];
    }
static void p16(NSMutableData* d, uint16_t v)
    {
    for (int i = 0; i < 2; i++)
        p8(d, (uint8_t)(v >> (8 * i)));
    }
static void p32(NSMutableData* d, uint32_t v)
    {
    for (int i = 0; i < 4; i++)
        p8(d, (uint8_t)(v >> (8 * i)));
    }
static void p64(NSMutableData* d, uint64_t v)
    {
    for (int i = 0; i < 8; i++)
        p8(d, (uint8_t)(v >> (8 * i)));
    }
static uint64_t alignUp(uint64_t v, uint64_t a)
    {
    return (v + a - 1) & ~(a - 1);
    }

static NSError* peErr(NSString* fmt, ...)
    {
    va_list ap;
    va_start(ap, fmt);
    NSString* m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:@"XTPEWriter"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : m}];
    }

// Trailing zeros need no file bytes: a section whose VirtualSize exceeds its
// SizeOfRawData is zero-filled by the loader, exactly as PT_LOAD's p_memsz is.
static uint64_t rawSizeOf(NSData* d)
    {
    const uint8_t* b = d.bytes;
    uint64_t n = d.length;
    while (n > 0 && b[n - 1] == 0)
        n--;
    return n;
    }

@implementation XTPEWriter

// ── COFF relocatable: the write direction ─────────────────────────────────
//
// The executable path RESOLVES the assembler's fixups against final RVAs. An
// object keeps the text verbatim and records every remaining fixup as a
// relocation. Stage 1 of private:docs/Design/separate-compilation.md, win64.
//
// COFF differs from ELF in one way that matters here: there is no explicit
// addend field. The addend lives INLINE in the patched bytes, and
// `IMAGE_REL_AMD64_REL32` means "relative to the byte four past the field". Our
// fixups mean `S + addend - P`, so the inline value is `addend + 4` and the
// relocation type is always plain REL32 — no need for the REL32_1..REL32_5
// variants, which exist precisely to express what an explicit addend already
// says. (That is why `mov [rip+x], imm32`, whose displacement sits eight bytes
// from the end of the instruction, needs no special case: its addend is -8, so
// the inline value is -4.)
//
// Layout: COFF header | 2 section headers | .text | .data | .text relocs
//         | .data relocs | symbol table | string table.
+ (nullable NSData*)objectFromText:(NSData*)text
                              data:(NSData*)dataIn
                           symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                       dataSymbols:(NSSet<NSString*>*)dataSymbols
                     globalSymbols:(NSSet<NSString*>*)globalSymbols
                            fixups:(NSArray<XAX86_64Fixup*>*)fixups
                             error:(NSError**)error
    {
    enum
        {
        REL_ADDR64 = 0x01,
        REL_REL32 = 0x04,
        SYM_CLASS_EXTERNAL = 2,
        SYM_CLASS_STATIC = 3,
        SEC_TEXT = 1,
        SEC_DATA = 2,
        SYM_SZ = 18,
        RELOC_SZ = 10,
        SCN_ALIGN_16 = 0x00500000,
        SCN_ALIGN_8 = 0x00400000
        };
    NSData* data = dataIn ?: [NSData data];
    NSMutableData *mtext = [text mutableCopy], *mdata = [data mutableCopy];

    // Symbols: defined (text then data) and then undefined, sorted within each
    // group so two builds of one input cannot differ by enumeration order.
    NSMutableArray<NSString*>* defText = [NSMutableArray array];
    NSMutableArray<NSString*>* defData = [NSMutableArray array];
    for (NSString* n in [symbols.allKeys sortedArrayUsingSelector:@selector(compare:)])
        {
        if ([n hasPrefix:@".L"])
            continue; // assembler-local, already resolved
        [([dataSymbols containsObject:n] ? defData : defText) addObject:n];
        }
    NSMutableSet<NSString*>* undefSet = [NSMutableSet set];
    for (XAX86_64Fixup* f in fixups)
        if (f.symbol && !symbols[f.symbol])
            [undefSet addObject:f.symbol];
    NSMutableArray<NSString*>* order = [NSMutableArray array];
    [order addObjectsFromArray:defText];
    [order addObjectsFromArray:defData];
    [order addObjectsFromArray:[undefSet.allObjects
                                   sortedArrayUsingSelector:@selector(compare:)]];
    NSMutableDictionary<NSString*, NSNumber*>* symIndex = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < order.count; i++)
        symIndex[order[i]] = @(i);

    // Relocations. The addend goes INTO the section bytes, so this patches the
    // blobs as it goes — which is why they were copied mutable above.
    NSMutableData *textRel = [NSMutableData data], *dataRel = [NSMutableData data];
    uint32_t nTextRel = 0, nDataRel = 0;
    uint8_t *tp = mtext.mutableBytes, *dp = mdata.mutableBytes;
    for (XAX86_64Fixup* f in fixups)
        {
        NSNumber* si = symIndex[f.symbol];
        if (!si)
            continue; // nothing names it
        if (f.kind == XAX86FixupAbs64)
            {
            if (f.offset + 8 > mdata.length)
                {
                if (error)
                    *error = peErr(@"abs64 fixup for '%@' past end of data", f.symbol);
                return nil;
                }
            uint64_t v = (uint64_t)f.addend; // S is added by the linker
            for (int i = 0; i < 8; i++)
                dp[f.offset + i] = (uint8_t)(v >> (8 * i));
            p32(dataRel, (uint32_t)f.offset);
            p32(dataRel, si.unsignedIntValue);
            p16(dataRel, REL_ADDR64);
            nDataRel++;
            continue;
            }
        if (f.offset + 4 > mtext.length)
            {
            if (error)
                *error = peErr(@"rel32 fixup for '%@' past end of text", f.symbol);
            return nil;
            }
        int32_t inl = (int32_t)(f.addend + 4);
        for (int i = 0; i < 4; i++)
            tp[f.offset + i] = (uint8_t)((uint32_t)inl >> (8 * i));
        p32(textRel, (uint32_t)f.offset);
        p32(textRel, si.unsignedIntValue);
        p16(textRel, REL_REL32);
        nTextRel++;
        }

    // String table: COFF inlines a name of 8 bytes or fewer and puts anything
    // longer here. xtc's mangled names are almost all longer.
    NSMutableData* strtab = [NSMutableData data];
    p32(strtab, 0); // size, patched at the end
    NSMutableArray<NSNumber*>* strx = [NSMutableArray array];
    for (NSString* n in order)
        {
        if (n.length <= 8)
            {
            [strx addObject:@0];
            continue;
            }
        [strx addObject:@(strtab.length)];
        [strtab appendData:[n dataUsingEncoding:NSUTF8StringEncoding]];
        p8(strtab, 0);
        }
        {
        uint32_t sz = (uint32_t)strtab.length;
        uint8_t* sb = strtab.mutableBytes;
        for (int i = 0; i < 4; i++)
            sb[i] = (uint8_t)(sz >> (8 * i));
        }

    uint64_t off = 20 + 2 * PE_SECT_HDR_SIZE;
    uint64_t textOff = off;
    off += mtext.length;
    uint64_t dataOff = off;
    off += mdata.length;
    uint64_t trelOff = off;
    off += textRel.length;
    uint64_t drelOff = off;
    off += dataRel.length;
    uint64_t symOff = off;
    off += order.count * SYM_SZ;

    NSMutableData* out = [NSMutableData data];
    p16(out, PE_MACHINE_AMD64);
    p16(out, 2 /*NumberOfSections*/);
    p32(out, 0 /*TimeDateStamp — zero keeps the object reproducible*/);
    p32(out, (uint32_t)symOff);
    p32(out, (uint32_t)order.count);
    p16(out, 0 /*SizeOfOptionalHeader — an object has none*/);
    p16(out, 0 /*Characteristics*/);

    void (^sect)(const char*, uint64_t, uint64_t, uint64_t, uint32_t, uint32_t) =
        ^(const char* nm, uint64_t sz, uint64_t raw, uint64_t rel, uint32_t nrel, uint32_t chars) {
          char nb[8] = {0};
          strncpy(nb, nm, 8);
          [out appendBytes:nb length:8];
          p32(out, 0 /*VirtualSize*/);
          p32(out, 0 /*VirtualAddress — 0 in an object*/);
          p32(out, (uint32_t)sz);
          p32(out, (uint32_t)(sz ? raw : 0));
          p32(out, (uint32_t)(nrel ? rel : 0));
          p32(out, 0 /*Linenumbers*/);
          p16(out, (uint16_t)nrel);
          p16(out, 0);
          p32(out, chars);
        };
    sect(".text", mtext.length, textOff, trelOff, nTextRel,
         PE_SCN_CODE | PE_SCN_MEM_EXECUTE | PE_SCN_MEM_READ | SCN_ALIGN_16);
    sect(".data", mdata.length, dataOff, drelOff, nDataRel,
         PE_SCN_INITIALIZED_DATA | PE_SCN_MEM_READ | PE_SCN_MEM_WRITE | SCN_ALIGN_8);

    [out appendData:mtext];
    [out appendData:mdata];
    [out appendData:textRel];
    [out appendData:dataRel];
    for (NSUInteger i = 0; i < order.count; i++)
        {
        NSString* n = order[i];
        BOOL isUndef = (symbols[n] == nil);
        BOOL inData = [dataSymbols containsObject:n];
        if (strx[i].unsignedIntValue == 0)
            {
            char nb[8] = {0};
            strncpy(nb, n.UTF8String, 8);
            [out appendBytes:nb length:8];
            }
        else
            {
            p32(out, 0);
            p32(out, strx[i].unsignedIntValue);
            }
        p32(out, isUndef ? 0 : symbols[n].unsignedIntValue);    // Value
        p16(out, isUndef ? 0 : (inData ? SEC_DATA : SEC_TEXT)); // SectionNumber
        p16(out, 0 /*Type*/);
        // A defined name that was never `.globl` stays STATIC, so two objects
        // with a same-named static helper do not collide at link.
        p8(out, (isUndef || [globalSymbols containsObject:n])
                    ? SYM_CLASS_EXTERNAL
                    : SYM_CLASS_STATIC);
        p8(out, 0 /*NumberOfAuxSymbols*/);
        }
    [out appendData:strtab];
    return out;
    }

// ── COFF relocatable: the read direction ──────────────────────────────────
// Same dictionary shape XTMachOWriter/XTElfWriter's readers return, so all
// three linkers' merge loops stay recognisably the same code. `addend` is read
// back OUT of the section bytes, since COFF keeps it there — and normalised to
// the assembler's convention (`S + addend - P`) by subtracting the 4 that
// REL32 implies, so the caller never has to know which container it came from.
+ (nullable NSDictionary*)objectAtPath:(NSString*)path
    {
    NSData* d = [NSData dataWithContentsOfFile:path];
    if (!d)
        return nil;
    return [self objectFromData:d];
    }

// The `ar` container is XTArArchive's job; this adds only "decode each member
// as a COFF object". A member that is not one is skipped rather than refused —
// mingw's import libraries carry `.idata` stub members and a linker-directive
// member alongside the real objects.
+ (nullable NSArray<NSDictionary*>*)objectsInArchive:(NSString*)path
    {
    NSArray<NSDictionary*>* members = [XTArArchive membersOfArchive:path];
    if (!members)
        return nil;
    NSMutableArray<NSDictionary*>* out = [NSMutableArray array];
    for (NSDictionary* mem in members)
        {
        NSDictionary* obj = [self objectFromData:mem[@"data"]];
        if (!obj)
            continue;
        NSMutableDictionary* m = [obj mutableCopy];
        m[@"member"] = mem[@"name"];
        [out addObject:m];
        }
    return out;
    }

+ (nullable NSDictionary*)objectFromData:(NSData*)d
    {
    enum
        {
        REL_ADDR64 = 0x01,
        REL_REL32 = 0x04,
        SYM_SZ = 18,
        RELOC_SZ = 10
        };
    if (d.length < 20)
        return nil;
    const uint8_t* b = d.bytes;
    uint16_t (^r16)(uint64_t) = ^uint16_t(uint64_t o) {
      return (uint16_t)(b[o] | (b[o + 1] << 8));
    };
    uint32_t (^r32)(uint64_t) = ^uint32_t(uint64_t o) {
      return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | ((uint32_t)b[o + 3] << 24);
    };
    uint64_t (^r64)(uint64_t) = ^uint64_t(uint64_t o) {
      uint64_t v = 0;
      for (int i = 0; i < 8; i++)
          v |= (uint64_t)b[o + i] << (8 * i);
      return v;
    };
    if (r16(0) != PE_MACHINE_AMD64 || r16(16) != 0)
        return nil; // not a bare COFF object
    uint16_t nsect = r16(2);
    uint32_t symOff = r32(8), nsym = r32(12);
    if (!nsect || symOff + (uint64_t)nsym * SYM_SZ > d.length)
        return nil;
    uint64_t strOff = symOff + (uint64_t)nsym * SYM_SZ;

    NSMutableArray<NSDictionary*>* secs = [NSMutableArray arrayWithObject:@{}]; // 1-based
    for (uint16_t i = 0; i < nsect; i++)
        {
        uint64_t s = 20 + (uint64_t)i * PE_SECT_HDR_SIZE;
        char nm[9] = {0};
        memcpy(nm, b + s, 8);
        [secs addObject:@{@"name" : @(nm), @"size" : @(r32(s + 16)), @"raw" : @(r32(s + 20)), @"rel" : @(r32(s + 24)), @"nrel" : @(r16(s + 32)), @"chars" : @(r32(s + 36))}];
        }
    // Sections a real toolchain's objects carry that this linker must NOT take.
    // Measured across mingw's libmingwex.a + libmsvcrt.a: every SECREL
    // relocation lives in a DISCARDABLE section (the DWARF `.debug_*` group,
    // which COFF names `/<offset>`), and every ADDR32NB lives in `.idata` or
    // `.pdata`. Dropping these is not a shortcut — it is what makes those two
    // relocation types unreachable, so the reader needs neither.
    //
    //   .idata  a DLL import descriptor. We build our own import table from the
    //           import map, so mingw's would be a second, conflicting one.
    //   .pdata  SEH unwind info, and .xdata its payload. Optional metadata;
    //           nothing we emit unwinds through it.
    BOOL (^skippable)(NSDictionary*) = ^BOOL(NSDictionary* s) {
      if ([s[@"chars"] unsignedIntValue] & PE_SCN_MEM_DISCARDABLE)
          return YES;
      NSString* n = s[@"name"];
      return [n hasPrefix:@".idata"] || [n hasPrefix:@".pdata"] ||
             [n hasPrefix:@".xdata"] || [n hasPrefix:@".debug"];
    };

    // A COFF object may hold MANY code sections — one per COMDAT function is
    // ordinary in a real libc. Taking only the first left the rest of the
    // member's code out of the image while still claiming its symbols.
    NSMutableData* textBlob = [NSMutableData data];
    NSMutableDictionary<NSNumber*, NSNumber*>* textOff = [NSMutableDictionary dictionary];
    NSUInteger textIdx = 0;
    for (NSUInteger i = 1; i < secs.count; i++)
        {
        if (!([secs[i][@"chars"] unsignedIntValue] & PE_SCN_CODE))
            continue;
        if (skippable(secs[i]))
            continue;
        while (textBlob.length & 15)
            {
            uint8_t z = 0;
            [textBlob appendBytes:&z length:1];
            }
        textOff[@(i)] = @(textBlob.length);
        if (!textIdx)
            textIdx = i;
        [textBlob appendBytes:b + [secs[i][@"raw"] unsignedLongLongValue]
                       length:[secs[i][@"size"] unsignedIntValue]];
        }
    if (!textIdx)
        return nil;
    NSData* text = textBlob;

    NSMutableData* data = [NSMutableData data];
    NSMutableDictionary<NSNumber*, NSNumber*>* blobOff = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < secs.count; i++)
        {
        if (textOff[@(i)])
            continue;
        uint32_t ch = [secs[i][@"chars"] unsignedIntValue];
        if (ch & PE_SCN_CODE)
            continue;
        if (skippable(secs[i]))
            continue;
        if (!(ch & (PE_SCN_INITIALIZED_DATA | PE_SCN_UNINIT_DATA)))
            continue;
        while (data.length & 7)
            {
            uint8_t z = 0;
            [data appendBytes:&z length:1];
            }
        blobOff[@(i)] = @(data.length);
        uint32_t sz = [secs[i][@"size"] unsignedIntValue];
        if (ch & PE_SCN_UNINIT_DATA)
            [data appendData:[NSMutableData dataWithLength:sz]];
        else
            [data appendBytes:b + [secs[i][@"raw"] unsignedLongLongValue] length:sz];
        }

    NSMutableDictionary<NSString*, NSNumber*>* syms = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* dsyms = [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* symnames = [NSMutableArray array];
    NSMutableArray<NSDictionary*>* symdefs = [NSMutableArray array];
    for (uint32_t i = 0; i < nsym; i++)
        {
        uint64_t e = symOff + (uint64_t)i * SYM_SZ;
        NSString* n;
        if (r32(e) == 0)
            n = [NSString stringWithUTF8String:(const char*)(b + strOff + r32(e + 4))] ?: @"";
        else
            {
            char nb[9] = {0};
            memcpy(nb, b + e, 8);
            n = @(nb);
            }
        uint32_t val = r32(e + 8);
        int16_t sect = (int16_t)r16(e + 12);
        uint8_t cls = b[e + 16], naux = b[e + 17];
        BOOL ext = (cls == 2);
        int where = 0;
        uint64_t off = 0;
        if (sect > 0 && textOff[@(sect)])
            {
            where = 1;
            off = textOff[@(sect)].unsignedLongLongValue + val;
            }
        else if (sect > 0 && blobOff[@(sect)])
            {
            where = 2;
            off = blobOff[@(sect)].unsignedLongLongValue + val;
            }
        [symnames addObject:n];
        [symdefs addObject:@{@"ext" : @(ext), @"where" : @(where), @"off" : @(off)}];
        if (n.length && ext && where == 1)
            syms[n] = @(off);
        else if (n.length && ext && where == 2)
            dsyms[n] = @(off);
        // Auxiliary records occupy symbol-table slots and are indexed by
        // relocations, so they must be kept as placeholders, not skipped.
        for (uint8_t a = 0; a < naux; a++)
            {
            i++;
            [symnames addObject:@""];
            [symdefs addObject:@{@"ext" : @NO, @"where" : @0, @"off" : @0}];
            }
        }

    NSMutableArray<NSDictionary*>* relocs = [NSMutableArray array];
    NSMutableArray<NSDictionary*>* datarelocs = [NSMutableArray array];
    for (NSUInteger i = 1; i < secs.count; i++)
        {
        uint32_t nrel = [secs[i][@"nrel"] unsignedIntValue];
        if (!nrel)
            continue;
        NSNumber* tOff = textOff[@(i)];
        BOOL toText = (tOff != nil);
        NSNumber* dOff = blobOff[@(i)];
        if (!toText && !dOff)
            continue; // a skipped section relocates nothing
        uint64_t rbase = [secs[i][@"rel"] unsignedLongLongValue];
        uint64_t sraw = [secs[i][@"raw"] unsignedLongLongValue];
        for (uint32_t r = 0; r < nrel; r++)
            {
            uint64_t e = rbase + (uint64_t)r * RELOC_SZ;
            uint32_t roff = r32(e);
            uint32_t rsym = r32(e + 4);
            uint16_t rt = r16(e + 8);
            int64_t addend;
            if (rt == REL_ADDR64)
                addend = (int64_t)r64(sraw + roff);
            else
                addend = (int32_t)r32(sraw + roff) - 4; // undo REL32's implied +4
            [(toText ? relocs : datarelocs) addObject:
                                                @{@"off" : @(roff + (toText ? tOff.unsignedLongLongValue
                                                                            : dOff.unsignedLongLongValue)),
                                                  @"sym" : @(rsym),
                                                  @"type" : @(rt),
                                                  @"addend" : @(addend)}];
            }
        }
    return @{@"text" : text, @"data" : data, @"symbols" : syms, @"datasyms" : dsyms, @"symnames" : symnames, @"symdefs" : symdefs, @"relocs" : relocs, @"datarelocs" : datarelocs};
    }

+ (nullable NSData*)executableFromText:(NSData*)textIn
                                  data:(NSData*)dataIn
                               symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                           dataSymbols:(NSSet<NSString*>*)dataSymbols
                                fixups:(NSArray<XAX86_64Fixup*>*)fixups
                           entrySymbol:(NSString*)entrySymbol
                               imports:(NSDictionary<NSString*, NSArray<NSString*>*>*)imports
                                 error:(NSError**)error
    {
    NSNumber* entry = symbols[entrySymbol];
    if (!entry || [dataSymbols containsObject:entrySymbol])
        {
        if (error)
            *error = peErr(@"entry symbol '%@' is not defined in the text section", entrySymbol);
        return nil;
        }

    // ── 1. which imports does this program actually use? ──
    // Only emit descriptors for what is referenced: an unused DLL in the import
    // table is a load-time dependency the program does not need.
    NSMutableDictionary<NSString*, NSString*>* ownerOf = [NSMutableDictionary dictionary];
    for (NSString* dll in imports)
        for (NSString* sym in imports[dll])
            ownerOf[sym] = dll;

    NSMutableArray<NSString*>* dllOrder = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSMutableArray<NSString*>*>* used = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* iatIndex = [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* stubSym = [NSMutableArray array]; // stub i → its symbol
    // One descriptor per DLL, matched case-INSENSITIVELY. Windows loads a DLL
    // once however it is spelled, and two descriptors for `kernel32.dll` and
    // `KERNEL32.dll` (which is what an imports map and a hand-written extern
    // between them produce) doubles the IAT for no gain.
    NSMutableDictionary<NSString*, NSString*>* canonDll = [NSMutableDictionary dictionary];
    // `__imp_X` is not a symbol in its own right — it is the ADDRESS OF X's IAT
    // slot, which is how a real toolchain's objects reference an import they
    // mean to call indirectly (`call [rip + __imp_X]`) or store. It therefore
    // needs X imported, but resolves to the slot rather than to a call stub, and
    // is legitimately a DATA reference — which is why the "function imports
    // only" rule below must not fire on it.
    NSString* (^impTarget)(NSString*) = ^NSString*(NSString* n) {
      return [n hasPrefix:@"__imp_"] ? [n substringFromIndex:6] : nil;
    };
    NSUInteger nImports = 0;
    for (XAX86_64Fixup* f in fixups)
        {
        NSString* viaImp = impTarget(f.symbol);
        NSString* want = viaImp ?: f.symbol;
        if (symbols[f.symbol] || iatIndex[want])
            continue;
        NSString* dll = ownerOf[want];
        if (!dll)
            {
            if (error)
                *error = peErr(@"undefined symbol '%@' — it is neither defined here "
                               @"nor listed as a DLL import",
                               f.symbol);
            return nil;
            }
        if (f.kind != XAX86FixupRel32 && !viaImp)
            {
            if (error)
                *error = peErr(@"'%@' is an undefined DATA symbol; only function "
                               @"imports are supported (a data import would need the "
                               @"referencing instruction rewritten to an indirection)",
                               f.symbol);
            return nil;
            }
        NSString* key = dll.lowercaseString;
        if (!canonDll[key])
            canonDll[key] = dll; // first spelling wins
        dll = canonDll[key];
        if (!used[dll])
            {
            used[dll] = [NSMutableArray array];
            [dllOrder addObject:dll];
            }
        [used[dll] addObject:want];
        iatIndex[want] = @(nImports++);
        [stubSym addObject:want];
        }

    // A symbol's IAT SLOT is not its stub index. The IAT is written per DLL with
    // a null terminator after each, so slot n of the whole array is not import
    // n — every symbol of the second DLL sits one slot further on than its
    // discovery order suggests. Indexing by the stub number was invisible while
    // programs imported a single DLL, and made the FIRST import of the second
    // DLL resolve to the first DLL's terminator: a `call` straight through a
    // null IAT entry, i.e. to address 0.
    NSMutableDictionary<NSString*, NSNumber*>* iatSlot = [NSMutableDictionary dictionary];
        {
        NSUInteger slot = 0;
        for (NSString* dll in dllOrder)
            {
            for (NSString* sym in used[dll])
                iatSlot[sym] = @(slot++);
            slot++; // this DLL's terminator
            }
        }

    // ── 2. sizes, then addresses ──
    // Nothing below depends on an address, so the whole layout is fixed before a
    // byte is written.
    NSMutableData* text = [textIn mutableCopy];
    NSMutableData* data = [dataIn mutableCopy];
    NSUInteger thunkOff = text.length; // stubs append to .text
    uint64_t textLen = text.length + nImports * PE_THUNK_SZ;

    // .rdata holds the import machinery: descriptors, then per-DLL ILT and IAT
    // (two identical arrays — the loader overwrites the IAT), then the hint/name
    // entries, then the DLL name strings.
    NSUInteger nDesc = dllOrder.count + 1; // + the null terminator
    uint64_t descSz = nDesc * 20;
    uint64_t thunkArraySz = 0; // one ILT + one IAT per DLL
    for (NSString* dll in dllOrder)
        thunkArraySz += (used[dll].count + 1) * 8;
    uint64_t iltSz = thunkArraySz, iatSz = thunkArraySz;

    uint32_t nSect = data.length ? 3 : 2; // .text, .rdata, [.data]
    uint64_t hdrSz = alignUp(0x40 + 0x40 + 4 + 20 + PE_OPT_HDR_SIZE + (uint64_t)nSect * PE_SECT_HDR_SIZE, PE_FILE_ALIGN);

    uint64_t textRVA = PE_SECT_ALIGN;
    uint64_t textRaw = hdrSz;
    uint64_t rdataRVA = alignUp(textRVA + textLen, PE_SECT_ALIGN);
    uint64_t rdataRaw = alignUp(textRaw + textLen, PE_FILE_ALIGN);
    uint64_t descRVA = rdataRVA;
    uint64_t iltRVA = descRVA + descSz;
    uint64_t iatRVA = iltRVA + iltSz;
    uint64_t namesRVA = iatRVA + iatSz;

    // Hint/name entries: u16 hint then the NUL-terminated name, 2-byte aligned.
    NSMutableDictionary<NSString*, NSNumber*>* nameRVA = [NSMutableDictionary dictionary];
    uint64_t cur = namesRVA;
    for (NSString* dll in dllOrder)
        for (NSString* sym in used[dll])
            {
            nameRVA[sym] = @(cur);
            cur = alignUp(cur + 2 + [sym lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1, 2);
            }
    NSMutableDictionary<NSString*, NSNumber*>* dllNameRVA = [NSMutableDictionary dictionary];
    for (NSString* dll in dllOrder)
        {
        dllNameRVA[dll] = @(cur);
        cur += [dll lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
        }
    uint64_t rdataLen = cur - rdataRVA;

    uint64_t dataRVA = alignUp(rdataRVA + rdataLen, PE_SECT_ALIGN);
    uint64_t dataRaw = alignUp(rdataRaw + rdataLen, PE_FILE_ALIGN);

    uint64_t textAddr = PE_IMAGE_BASE + textRVA;
    uint64_t dataAddr = PE_IMAGE_BASE + dataRVA;
    uint64_t thunkAddr = textAddr + thunkOff;

    // ── 3. import stubs ──
    for (NSUInteger i = 0; i < nImports; i++)
        {
        uint64_t here = thunkAddr + i * PE_THUNK_SZ;
        uint64_t slot = iatSlot[stubSym[i]].unsignedLongLongValue;
        int64_t rel = (int64_t)(PE_IMAGE_BASE + iatRVA + slot * 8) - (int64_t)(here + PE_THUNK_SZ);
        p8(text, 0xFF);
        p8(text, 0x25); // jmp qword ptr [rip + disp32]
        p32(text, (uint32_t)(int32_t)rel);
        }

    // ── 4. resolve fixups ──
    uint8_t *tp = text.mutableBytes, *dp = data.mutableBytes;
    for (XAX86_64Fixup* f in fixups)
        {
        NSNumber* off = symbols[f.symbol];
        NSString* viaImp = impTarget(f.symbol);
        uint64_t target;
        if (off)
            target = ([dataSymbols containsObject:f.symbol] ? dataAddr : textAddr) + off.unsignedLongLongValue;
        else if (viaImp)
            target = PE_IMAGE_BASE + iatRVA + iatSlot[viaImp].unsignedLongLongValue * 8;
        else
            target = thunkAddr + iatIndex[f.symbol].unsignedIntegerValue * PE_THUNK_SZ;

        if (f.kind == XAX86FixupAbs64)
            {
            if (f.offset + 8 > data.length)
                {
                if (error)
                    *error = peErr(@"abs64 fixup for '%@' past end of data", f.symbol);
                return nil;
                }
            uint64_t v = target + (uint64_t)f.addend;
            for (int i = 0; i < 8; i++)
                dp[f.offset + i] = (uint8_t)(v >> (8 * i));
            continue;
            }
        if (f.offset + 4 > text.length)
            {
            if (error)
                *error = peErr(@"pc32 fixup for '%@' past end of text", f.symbol);
            return nil;
            }
        int64_t rel = (int64_t)target - (int64_t)(textAddr + f.offset) + f.addend;
        if (rel < INT32_MIN || rel > INT32_MAX)
            {
            if (error)
                *error = peErr(@"'%@' is %lld bytes away — out of rel32 range",
                               f.symbol, (long long)rel);
            return nil;
            }
        for (int i = 0; i < 4; i++)
            tp[f.offset + i] = (uint8_t)((uint64_t)rel >> (8 * i));
        }
    // An abs64 in .data holds a full VA, which is only correct if the image
    // really loads at ImageBase — hence DYNAMIC_BASE stays off (see PE_IMAGE_BASE).

    // Measure the file size AFTER patching: a vtable slot that held a symbolic
    // .quad was zero until the abs64 fixup above wrote its VA. Measuring before
    // would count it as a trailing zero, drop it from the file, and the slot
    // would read back null — a virtual call straight to address 0.
    uint64_t dataFileSz = rawSizeOf(data);

    // ── 5. the file ──
    NSMutableData* out = [NSMutableData data];
    // DOS header. Windows does not care about the stub, but it must be present
    // and e_lfanew must point at the PE signature.
    p8(out, 'M');
    p8(out, 'Z');
    for (int i = 2; i < 0x3C; i++)
        p8(out, 0);
    // e_lfanew points PAST the stub, which occupies 0x40..0x7F. Pointing it at
    // 0x40 puts the stub where the PE header is claimed to be, and the loader
    // spins on the garbage it finds.
    p32(out, 0x80);
    // A stub that prints the usual message if run under DOS.
    const uint8_t stub[] = {
        0x0E, 0x1F, 0xBA, 0x0E, 0x00, 0xB4, 0x09, 0xCD, 0x21, 0xB8, 0x01, 0x4C, 0xCD, 0x21,
        'T', 'h', 'i', 's', ' ', 'p', 'r', 'o', 'g', 'r', 'a', 'm', ' ', 'c', 'a', 'n', 'n', 'o', 't',
        ' ', 'b', 'e', ' ', 'r', 'u', 'n', ' ', 'i', 'n', ' ', 'D', 'O', 'S', ' ', 'm', 'o', 'd', 'e', '.',
        '\r', '\r', '\n', '$'};
    [out appendBytes:stub length:sizeof stub];
    while (out.length < 0x80)
        p8(out, 0);

    p32(out, 0x00004550); // "PE\0\0"
    p16(out, PE_MACHINE_AMD64);
    p16(out, (uint16_t)nSect);
    p32(out, 0); // TimeDateStamp — 0 keeps
    p32(out, 0); //   the output reproducible
    p32(out, 0); // NumberOfSymbols
    p16(out, PE_OPT_HDR_SIZE);
    p16(out, PE_CHAR_EXECUTABLE | PE_CHAR_LARGE_ADDRESS);

    // Optional header (PE32+).
    p16(out, PE_MAGIC_PE32PLUS);
    p8(out, 14);
    p8(out, 0);                                          // linker version
    p32(out, (uint32_t)alignUp(textLen, PE_FILE_ALIGN)); // SizeOfCode
    p32(out, (uint32_t)alignUp(rdataLen + dataFileSz, PE_FILE_ALIGN));
    p32(out, 0);                                                 // SizeOfUninitializedData
    p32(out, (uint32_t)(textRVA + entry.unsignedLongLongValue)); // AddressOfEntryPoint
    p32(out, (uint32_t)textRVA);                                 // BaseOfCode
    p64(out, PE_IMAGE_BASE);
    p32(out, PE_SECT_ALIGN);
    p32(out, PE_FILE_ALIGN);
    p16(out, 6);
    p16(out, 0); // OS version 6.0
    p16(out, 0);
    p16(out, 0); // image version
    p16(out, 6);
    p16(out, 0); // subsystem version 6.0
    p32(out, 0); // Win32VersionValue
    uint64_t sizeOfImage = alignUp(data.length ? dataRVA + data.length
                                               : rdataRVA + rdataLen,
                                   PE_SECT_ALIGN);
    p32(out, (uint32_t)sizeOfImage);
    p32(out, (uint32_t)hdrSz);
    p32(out, 0); // CheckSum — only DLLs/drivers need one
    p16(out, PE_SUBSYSTEM_CUI);
    p16(out, 0); // DllCharacteristics: no DYNAMIC_BASE,
                 //   so the loader honours ImageBase
    p64(out, 0x100000);
    p64(out, 0x1000); // stack reserve / commit
    p64(out, 0x100000);
    p64(out, 0x1000); // heap  reserve / commit
    p32(out, 0);      // LoaderFlags
    p32(out, PE_NUM_DIRECTORIES);
    for (int i = 0; i < PE_NUM_DIRECTORIES; i++)
        {
        if (i == PE_DIR_IMPORT && nImports)
            {
            p32(out, (uint32_t)descRVA);
            p32(out, (uint32_t)descSz);
            }
        else if (i == PE_DIR_IAT && nImports)
            {
            p32(out, (uint32_t)iatRVA);
            p32(out, (uint32_t)iatSz);
            }
        else
            {
            p32(out, 0);
            p32(out, 0);
            }
        }

    // Section headers.
    void (^sect)(const char*, uint64_t, uint64_t, uint64_t, uint64_t, uint32_t) =
        ^(const char* nm, uint64_t vsize, uint64_t rva, uint64_t rawsz, uint64_t rawptr, uint32_t chars) {
          for (int i = 0; i < 8; i++)
              p8(out, (uint8_t)(nm[i] ? nm[i] : 0));
          p32(out, (uint32_t)vsize);
          p32(out, (uint32_t)rva);
          p32(out, (uint32_t)alignUp(rawsz, PE_FILE_ALIGN));
          p32(out, (uint32_t)rawptr);
          p32(out, 0);
          p32(out, 0);
          p16(out, 0);
          p16(out, 0);
          p32(out, chars);
        };
    sect(".text\0\0\0", textLen, textRVA, textLen, textRaw,
         PE_SCN_CODE | PE_SCN_MEM_EXECUTE | PE_SCN_MEM_READ);
    sect(".rdata\0\0", rdataLen, rdataRVA, rdataLen, rdataRaw,
         PE_SCN_INITIALIZED_DATA | PE_SCN_MEM_READ);
    if (data.length)
        sect(".data\0\0\0", data.length, dataRVA, dataFileSz, dataRaw,
             PE_SCN_INITIALIZED_DATA | PE_SCN_MEM_READ | PE_SCN_MEM_WRITE);

    while (out.length < textRaw)
        p8(out, 0);
    [out appendData:text];

    while (out.length < rdataRaw)
        p8(out, 0);
    // Import Directory Table, then the null terminator.
    uint64_t iltCur = iltRVA, iatCur = iatRVA;
    for (NSString* dll in dllOrder)
        {
        p32(out, (uint32_t)iltCur); // OriginalFirstThunk (ILT)
        p32(out, 0);
        p32(out, 0);                                // TimeDateStamp, ForwarderChain
        p32(out, dllNameRVA[dll].unsignedIntValue); // Name
        p32(out, (uint32_t)iatCur);                 // FirstThunk (IAT)
        iltCur += (used[dll].count + 1) * 8;
        iatCur += (used[dll].count + 1) * 8;
        }
    for (int i = 0; i < 5; i++)
        p32(out, 0); // null descriptor

    // ILT and IAT are identical on disk; the loader replaces the IAT in memory.
    for (int pass = 0; pass < 2; pass++)
        for (NSString* dll in dllOrder)
            {
            for (NSString* sym in used[dll])
                p64(out, nameRVA[sym].unsignedLongLongValue);
            p64(out, 0); // terminator
            }

    for (NSString* dll in dllOrder)
        for (NSString* sym in used[dll])
            {
            p16(out, 0); // hint — 0 means "search by name"
            [out appendData:[sym dataUsingEncoding:NSUTF8StringEncoding]];
            p8(out, 0);
            if (out.length & 1)
                p8(out, 0); // entries are 2-byte aligned
            }
    for (NSString* dll in dllOrder)
        {
        [out appendData:[dll dataUsingEncoding:NSUTF8StringEncoding]];
        p8(out, 0);
        }

    if (data.length)
        {
        while (out.length < dataRaw)
            p8(out, 0);
        [out appendData:[data subdataWithRange:NSMakeRange(0, (NSUInteger)dataFileSz)]];
        }
    // Every section's raw data is FileAlignment-padded; a short final section
    // makes some loaders reject the image.
    while (out.length % PE_FILE_ALIGN)
        p8(out, 0);
    return out;
    }

@end
