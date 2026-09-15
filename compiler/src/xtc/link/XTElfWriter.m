#import "XTElfWriter.h"
#import "XTArArchive.h"

// ELF64 constants (defined in-house — we don't include Linux headers).
enum
    {
    ET_EXEC = 2,
    ET_DYN = 3,
    EM_X86_64 = 62,
    PT_LOAD = 1,
    PT_DYNAMIC = 2,
    PT_INTERP = 3,
    PT_PHDR = 6,
    PT_GNU_STACK = 0x6474e551,
    PF_X = 1,
    PF_W = 2,
    PF_R = 4,
    };

#define ELF_PAGE 0x1000ull
#define ELF_VBASE 0x400000ull // classic x86-64 static-exec load base
#define EHDR_SZ 64
#define PHDR_SZ 56

static void put8v(NSMutableData* d, uint8_t v)
    {
    [d appendBytes:&v length:1];
    }
static void put16v(NSMutableData* d, uint16_t v)
    {
    for (int i = 0; i < 2; i++)
        put8v(d, (uint8_t)(v >> (8 * i)));
    }
static void put32v(NSMutableData* d, uint32_t v)
    {
    for (int i = 0; i < 4; i++)
        put8v(d, (uint8_t)(v >> (8 * i)));
    }
static void put64v(NSMutableData* d, uint64_t v)
    {
    for (int i = 0; i < 8; i++)
        put8v(d, (uint8_t)(v >> (8 * i)));
    }
static uint64_t roundUpTo(uint64_t v, uint64_t a)
    {
    return (v + a - 1) & ~(a - 1);
    }

// How many bytes of `d` actually need to be in the FILE. A PT_LOAD whose
// p_memsz exceeds its p_filesz has the difference zero-filled by the kernel, so
// a trailing run of zeros — which is what .bss is, and what a zero-initialised
// .data array is too — can simply be left out. Without this a program with a
// large zero array carries every byte of it on disk.
static uint64_t fileSizeOf(NSData* d)
    {
    const uint8_t* b = d.bytes;
    uint64_t n = d.length;
    while (n > 0 && b[n - 1] == 0)
        n--;
    return n;
    }

static NSError* elfErr(NSString* fmt, ...)
    {
    va_list ap;
    va_start(ap, fmt);
    NSString* m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:@"XTElfWriter"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : m}];
    }

// The layout, in one place — both the writer and the fixup pass need it, and a
// caller that re-derives it gets the addresses subtly wrong.
// text, [data], GNU_STACK
static uint32_t phdrCountFor(BOOL hasData)
    {
    return hasData ? 3 : 2;
    }
// File offset of the code, which shares its first page with the headers.
static uint64_t textOffsetFor(uint32_t nphdr)
    {
    return roundUpTo(EHDR_SZ + (uint64_t)nphdr * PHDR_SZ, 16);
    }
// The data segment starts on the page after the code, so it gets its own RW
// mapping without sharing a page with the executable one.
static uint64_t dataOffsetFor(BOOL hasData, uint64_t textLen)
    {
    return roundUpTo(textOffsetFor(phdrCountFor(hasData)) + textLen, ELF_PAGE);
    }

// ─────────────────────────── ET_DYN support ───────────────────────────
enum
    {
    DT_NULL = 0,
    DT_NEEDED = 1,
    DT_HASH = 4,
    DT_STRTAB = 5,
    DT_SYMTAB = 6,
    DT_RELA = 7,
    DT_RELASZ = 8,
    DT_RELAENT = 9,
    DT_STRSZ = 10,
    DT_SYMENT = 11,
    DT_SONAME = 14,
    DT_RUNPATH = 29,
    R_X86_64_64 = 1,
    R_X86_64_GLOB_DAT = 6,
    R_X86_64_RELATIVE = 8,
    STB_GLOBAL = 1,
    STT_FUNC = 2,
    STT_OBJECT = 1,
    SYM_SZ = 24,
    RELA_SZ = 24,
    DYN_SZ = 16,
    THUNK_SZ = 6, // ff 25 <rel32>  =  jmp qword ptr [rip + got]
    };

// The SysV ELF hash, as DT_HASH requires. Unchanged since 1995 and specified
// byte-for-byte in the gABI, so it is written out rather than looked up.
static uint32_t elfHash(const char* name)
    {
    uint32_t h = 0, g;
    while (*name)
        {
        h = (h << 4) + (uint8_t)*name++;
        if ((g = h & 0xF0000000u))
            h ^= g >> 24;
        h &= ~g;
        }
    return h;
    }

@implementation XTElfWriter

+ (uint64_t)textAddressWithDataSegment:(BOOL)hasData
    {
    return ELF_VBASE + textOffsetFor(hasData ? 3 : 2);
    }

// ── ET_REL: the write direction ───────────────────────────────────────────
//
// The executable and `.so` paths RESOLVE the assembler's fixups against final
// addresses. An object does the opposite: it keeps the text verbatim and
// records every remaining fixup as a relocation, leaving the binding to
// whoever links it. Stage 1 of private:docs/Design/separate-compilation.md, x86_64.
//
// The fixup kinds map onto ELF exactly, with no arithmetic to redo: the
// assembler already stores the addend as "what to add to S - P", which IS
// r_addend for a PC-relative relocation — including the awkward case of a
// RIP-relative operand with a trailing immediate, where the displacement is
// more than 4 bytes from the end of the instruction.
//
// Layout: ehdr | .text | .data | .rela.text | .rela.data | .symtab | .strtab
//         | .shstrtab | section headers. The two RELA sections are emitted
// even when empty so the section indices are fixed — a conditional section
// means every index below it moves, which is how a section table and its
// sh_link fields drift apart.
+ (nullable NSData*)objectFromText:(NSData*)text
                              data:(NSData*)dataIn
                           symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                       dataSymbols:(NSSet<NSString*>*)dataSymbols
                     globalSymbols:(NSSet<NSString*>*)globalSymbols
                           commons:(nullable NSDictionary<NSString*, NSArray<NSNumber*>*>*)commons
                            fixups:(NSArray<XAX86_64Fixup*>*)fixups
                             error:(NSError**)error
    {
    enum
        {
        SHT_PROGBITS = 1,
        SHT_SYMTAB = 2,
        SHT_STRTAB = 3,
        SHT_RELA = 4,
        SHF_WRITE = 1,
        SHF_ALLOC = 2,
        SHF_EXECINSTR = 4,
        STB_LOCAL = 0,
        STT_NOTYPE = 0,
        R_X86_64_PC32 = 2,
        R_X86_64_PLT32 = 4,
        SEC_TEXT = 1,
        SEC_DATA = 2,
        SEC_RELA_TEXT = 3,
        SEC_RELA_DATA = 4,
        SEC_SYMTAB = 5,
        SEC_STRTAB = 6,
        SEC_SHSTRTAB = 7,
        SEC_COUNT = 8,
        SHN_COMMON = 0xFFF2
        };
    NSData* data = dataIn ?: [NSData data];

    // ── symbol table ──────────────────────────────────────────────────────
    // ELF requires every STB_LOCAL symbol to precede every global, and
    // sh_info of .symtab to be the index of the first global — so the order is
    // locals, defined globals (text then data), undefined. Sorted within each
    // group, so two builds of one input cannot differ by a dictionary's
    // enumeration order.
    NSMutableArray<NSString*>* locals = [NSMutableArray array];
    NSMutableArray<NSString*>* defText = [NSMutableArray array];
    NSMutableArray<NSString*>* defData = [NSMutableArray array];
    for (NSString* n in [symbols.allKeys sortedArrayUsingSelector:@selector(compare:)])
        {
        if ([n hasPrefix:@".L"])
            continue; // assembler-local, already resolved
        if (![globalSymbols containsObject:n])
            {
            [locals addObject:n];
            continue;
            }
        [([dataSymbols containsObject:n] ? defData : defText) addObject:n];
        }
    NSMutableSet<NSString*>* undefSet = [NSMutableSet set];
    for (XAX86_64Fixup* f in fixups)
        if (f.symbol && !symbols[f.symbol])
            [undefSet addObject:f.symbol];
    NSArray<NSString*>* undef = [undefSet.allObjects
        sortedArrayUsingSelector:@selector(compare:)];

    NSArray<NSString*>* commonNames = [(commons.allKeys ?: @[])
        sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSString*>* order = [NSMutableArray array];
    [order addObjectsFromArray:locals];
    NSUInteger firstGlobal = order.count + 1; // +1 for the null symbol
    [order addObjectsFromArray:defText];
    [order addObjectsFromArray:defData];
    [order addObjectsFromArray:commonNames]; // COMMON symbols are global
    [order addObjectsFromArray:undef];
    NSMutableDictionary<NSString*, NSNumber*>* symIndex = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < order.count; i++)
        symIndex[order[i]] = @(i + 1);

    // Function sizes (st_size) for defined TEXT symbols, so the linker can GC
    // unreferenced functions (bug 196 Stage B). Functions are the non-.L text
    // symbols; sorted by offset they delimit one another, the last running to
    // the end of .text. Gives OUR objects the st_size clang objects already carry.
    NSMutableArray<NSString*>* fnames = [NSMutableArray array];
    for (NSString* n in defText)
        if (symbols[n])
            [fnames addObject:n];
    for (NSString* n in locals)
        if (symbols[n] && ![dataSymbols containsObject:n])
            [fnames addObject:n];
    [fnames sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
      uint64_t oa = symbols[a].unsignedLongLongValue, ob = symbols[b].unsignedLongLongValue;
      return oa < ob ? NSOrderedAscending : (oa > ob ? NSOrderedDescending : NSOrderedSame);
    }];
    NSMutableDictionary<NSString*, NSNumber*>* funcSize = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < fnames.count; i++)
        {
        uint64_t o0 = symbols[fnames[i]].unsignedLongLongValue;
        uint64_t o1 = text.length;
        for (NSUInteger j = i + 1; j < fnames.count; j++) // next DISTINCT offset (aliases share one)
            if (symbols[fnames[j]].unsignedLongLongValue > o0)
                {
                o1 = symbols[fnames[j]].unsignedLongLongValue;
                break;
                }
        funcSize[fnames[i]] = @(o1 >= o0 ? o1 - o0 : 0);
        }
    // The same for DATA symbols, so the linker's dead-data GC can split an
    // object's .data at every symbol (a size-0 data symbol is never a unit
    // boundary — it cannot say where it ends).
    NSMutableArray<NSString*>* dnames = [NSMutableArray array];
    for (NSString* n in [symbols.allKeys sortedArrayUsingSelector:@selector(compare:)])
        if (![n hasPrefix:@".L"] && [dataSymbols containsObject:n])
            [dnames addObject:n];
    [dnames sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
      uint64_t oa = symbols[a].unsignedLongLongValue, ob = symbols[b].unsignedLongLongValue;
      return oa < ob ? NSOrderedAscending : (oa > ob ? NSOrderedDescending : NSOrderedSame);
    }];
    for (NSUInteger i = 0; i < dnames.count; i++)
        {
        uint64_t o0 = symbols[dnames[i]].unsignedLongLongValue;
        uint64_t o1 = dataIn.length;
        for (NSUInteger j = i + 1; j < dnames.count; j++)
            if (symbols[dnames[j]].unsignedLongLongValue > o0)
                {
                o1 = symbols[dnames[j]].unsignedLongLongValue;
                break;
                }
        funcSize[dnames[i]] = @(o1 >= o0 ? o1 - o0 : 0);
        }

    NSMutableData* strtab = [NSMutableData data];
    put8v(strtab, 0);
    NSMutableData* symtab = [NSMutableData data];
    for (int i = 0; i < SYM_SZ; i++)
        put8v(symtab, 0); // the null symbol
    for (NSString* n in order)
        {
        NSArray<NSNumber*>* com = commons[n];
        put32v(symtab, (uint32_t)strtab.length);
        [strtab appendData:[n dataUsingEncoding:NSUTF8StringEncoding]];
        put8v(strtab, 0);
        if (com)
            {
            // A COMMON (tentative def): SHN_COMMON, st_value = required
            // alignment, st_size = byte size. The linker allocates one slot and
            // every unit that names it binds to that (C tentative-def merge).
            put8v(symtab, (uint8_t)((STB_GLOBAL << 4) | STT_OBJECT));
            put8v(symtab, 0);
            put16v(symtab, (uint16_t)SHN_COMMON);
            put64v(symtab, com[1].unsignedLongLongValue); // st_value = align
            put64v(symtab, com[0].unsignedLongLongValue); // st_size  = size
            continue;
            }
        BOOL isUndef = (symbols[n] == nil);
        BOOL inData = [dataSymbols containsObject:n];
        uint8_t bind = (isUndef || [globalSymbols containsObject:n]) ? STB_GLOBAL : STB_LOCAL;
        uint8_t type = isUndef ? STT_NOTYPE : (inData ? STT_OBJECT : STT_FUNC);
        put8v(symtab, (uint8_t)((bind << 4) | type));
        put8v(symtab, 0);
        put16v(symtab, isUndef ? 0 : (inData ? SEC_DATA : SEC_TEXT));
        put64v(symtab, isUndef ? 0 : symbols[n].unsignedLongLongValue);
        put64v(symtab, (!isUndef && funcSize[n]) ? funcSize[n].unsignedLongLongValue : 0); // st_size (symbol extent, bug 196)
        }

    // ── relocations, split by the section the fixup patches ───────────────
    // An Abs64 fixup is a `.quad <symbol>` inside .data; the two PC-relative
    // kinds patch an instruction in .text.
    NSMutableData *textRel = [NSMutableData data], *dataRel = [NSMutableData data];
    for (XAX86_64Fixup* f in fixups)
        {
        NSNumber* si = symIndex[f.symbol];
        if (!si)
            continue; // nothing names it; nothing to bind
        uint64_t info = ((uint64_t)si.unsignedIntValue << 32);
        if (f.kind == XAX86FixupAbs64)
            {
            if (f.offset + 8 > data.length)
                {
                if (error)
                    *error = elfErr(@"abs64 fixup for '%@' past end of data", f.symbol);
                return nil;
                }
            put64v(dataRel, f.offset);
            put64v(dataRel, info | R_X86_64_64);
            put64v(dataRel, (uint64_t)f.addend);
            continue;
            }
        if (f.offset + 4 > text.length)
            {
            if (error)
                *error = elfErr(@"pc32 fixup for '%@' past end of text", f.symbol);
            return nil;
            }
        // PLT32 for a call/jmp target and PC32 for a data reference, matching
        // what clang emits — both resolve identically for a defined symbol, and
        // a linker that treats them differently expects the distinction.
        uint64_t rt = (f.kind == XAX86FixupRel32) ? R_X86_64_PLT32 : R_X86_64_PC32;
        put64v(textRel, f.offset);
        put64v(textRel, info | rt);
        put64v(textRel, (uint64_t)f.addend);
        }

    // ── section names, then file offsets ──────────────────────────────────
    NSArray<NSString*>* secNames = @[ @"", @".text", @".data", @".rela.text",
                                      @".rela.data", @".symtab", @".strtab", @".shstrtab" ];
    NSMutableData* shstr = [NSMutableData data];
    put8v(shstr, 0);
    NSMutableArray<NSNumber*>* shName = [NSMutableArray array];
    for (NSString* n in secNames)
        {
        if (!n.length)
            {
            [shName addObject:@0];
            continue;
            }
        [shName addObject:@(shstr.length)];
        [shstr appendData:[n dataUsingEncoding:NSUTF8StringEncoding]];
        put8v(shstr, 0);
        }

    uint64_t off = EHDR_SZ;
    uint64_t textOff = (off = roundUpTo(off, 16));
    off += text.length;
    uint64_t dataOff = (off = roundUpTo(off, 8));
    off += data.length;
    uint64_t trelOff = (off = roundUpTo(off, 8));
    off += textRel.length;
    uint64_t drelOff = (off = roundUpTo(off, 8));
    off += dataRel.length;
    uint64_t symOff = (off = roundUpTo(off, 8));
    off += symtab.length;
    uint64_t strOff = off;
    off += strtab.length;
    uint64_t shstOff = off;
    off += shstr.length;
    uint64_t shOff = roundUpTo(off, 8);

    NSMutableData* out = [NSMutableData data];
    const uint8_t ident[16] = {0x7f, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    [out appendBytes:ident length:16];
    put16v(out, 1 /*ET_REL*/);
    put16v(out, EM_X86_64);
    put32v(out, 1 /*EV_CURRENT*/);
    put64v(out, 0 /*e_entry*/);
    put64v(out, 0 /*e_phoff*/);
    put64v(out, shOff);
    put32v(out, 0 /*e_flags*/);
    put16v(out, EHDR_SZ);
    put16v(out, 0);
    put16v(out, 0); // no program headers
    put16v(out, 64 /*e_shentsize*/);
    put16v(out, SEC_COUNT);
    put16v(out, SEC_SHSTRTAB);

    void (^pad)(uint64_t) = ^(uint64_t to) {
      while (out.length < to)
          put8v(out, 0);
    };
    pad(textOff);
    [out appendData:text];
    pad(dataOff);
    [out appendData:data];
    pad(trelOff);
    [out appendData:textRel];
    pad(drelOff);
    [out appendData:dataRel];
    pad(symOff);
    [out appendData:symtab];
    pad(strOff);
    [out appendData:strtab];
    pad(shstOff);
    [out appendData:shstr];
    pad(shOff);

    // name, type, flags, addr, offset, size, link, info, align, entsize
    void (^shdr)(NSUInteger, uint32_t, uint64_t, uint64_t, uint64_t,
                 uint32_t, uint32_t, uint64_t, uint64_t) =
        ^(NSUInteger nameIdx, uint32_t type, uint64_t flags, uint64_t offset, uint64_t size,
          uint32_t link, uint32_t info, uint64_t align, uint64_t entsz) {
          put32v(out, shName[nameIdx].unsignedIntValue);
          put32v(out, type);
          put64v(out, flags);
          put64v(out, 0 /*sh_addr: 0 in an object*/);
          put64v(out, offset);
          put64v(out, size);
          put32v(out, link);
          put32v(out, info);
          put64v(out, align);
          put64v(out, entsz);
        };
    shdr(0, 0, 0, 0, 0, 0, 0, 0, 0);
    shdr(SEC_TEXT, SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR, textOff, text.length, 0, 0, 16, 0);
    shdr(SEC_DATA, SHT_PROGBITS, SHF_ALLOC | SHF_WRITE, dataOff, data.length, 0, 0, 8, 0);
    shdr(SEC_RELA_TEXT, SHT_RELA, 0, trelOff, textRel.length, SEC_SYMTAB, SEC_TEXT, 8, RELA_SZ);
    shdr(SEC_RELA_DATA, SHT_RELA, 0, drelOff, dataRel.length, SEC_SYMTAB, SEC_DATA, 8, RELA_SZ);
    shdr(SEC_SYMTAB, SHT_SYMTAB, 0, symOff, symtab.length, SEC_STRTAB,
         (uint32_t)firstGlobal, 8, SYM_SZ);
    shdr(SEC_STRTAB, SHT_STRTAB, 0, strOff, strtab.length, 0, 0, 1, 0);
    shdr(SEC_SHSTRTAB, SHT_STRTAB, 0, shstOff, shstr.length, 0, 0, 1, 0);
    return out;
    }

// ── ET_REL: the read direction ────────────────────────────────────────────
//
// Parse a relocatable object into the same shape XTMachOWriter+objectAtPath:
// returns, so the two linkers' merge loops read alike: `text` / `data` blobs,
// `symnames` + parallel `symdefs` (where 0=undef 1=text 2=data, off, ext), the
// external defs split into `symbols` / `datasyms` for the pull decision, and
// the relocations against each of the two blobs.
//
// Written against OUR objects but deliberately general — several data-like
// sections concatenated with their blob offsets recorded, SHT_NOBITS
// zero-filled — because an object that only we can read is not evidence that
// we produce a real one.
+ (nullable NSDictionary*)objectAtPath:(NSString*)path
    {
    return [self objectFromData:[NSData dataWithContentsOfFile:path]];
    }

// The `ar` container itself is XTArArchive's job — it is the one thing Mach-O,
// ELF and COFF static libraries share, and all this adds is decoding each
// member as an ELF object. A member that is not one is skipped rather than
// refused: real archives carry non-object members.
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

+ (nullable NSDictionary*)sharedInfoAtPath:(NSString*)path
    {
    enum
        {
        SHT_STRTAB = 3,
        SHT_DYNAMIC = 6,
        SHT_DYNSYM = 11,
        DT_SONAME = 14,
        STB_GLOBAL = 1,
        STB_WEAK = 2
        };
    NSData* d = [NSData dataWithContentsOfFile:path];
    if (d.length < EHDR_SZ)
        return nil;
    const uint8_t* b = d.bytes;
    if (memcmp(b, "\x7f"
                  "ELF",
               4) != 0 ||
        b[4] != 2 || b[5] != 1)
        return nil; // ELF64 LE
    uint16_t (^rd16)(uint64_t) = ^uint16_t(uint64_t o) {
      return (uint16_t)(b[o] | (b[o + 1] << 8));
    };
    uint32_t (^rd32)(uint64_t) = ^uint32_t(uint64_t o) {
      return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | ((uint32_t)b[o + 3] << 24);
    };
    uint64_t (^rd64)(uint64_t) = ^uint64_t(uint64_t o) {
      uint64_t v = 0;
      for (int i = 0; i < 8; i++)
          v |= (uint64_t)b[o + i] << (8 * i);
      return v;
    };
    if (rd16(16) != 3 /*ET_DYN*/)
        return nil;

    // Section headers carry the .dynsym/.dynstr/.dynamic we need; our own writer
    // emits them (ld.so reads program headers, but `nm`/gdb and this reader want
    // sections). A stripped .so with no section headers is not something we
    // produce, so a section-based read is sufficient here.
    uint64_t shoff = rd64(40);
    uint16_t shentsize = rd16(58), shnum = rd16(60);
    if (!shnum || shoff + (uint64_t)shnum * shentsize > d.length)
        return nil;
    uint64_t dynsymOff = 0, dynsymSz = 0, dynsymLink = 0, dynamicOff = 0, dynamicSz = 0;
    for (uint16_t i = 0; i < shnum; i++)
        {
        uint64_t s = shoff + (uint64_t)i * shentsize;
        uint32_t type = rd32(s + 4);
        if (type == SHT_DYNSYM)
            {
            dynsymOff = rd64(s + 24);
            dynsymSz = rd64(s + 32);
            dynsymLink = rd32(s + 40);
            }
        else if (type == SHT_DYNAMIC)
            {
            dynamicOff = rd64(s + 24);
            dynamicSz = rd64(s + 32);
            }
        }
    if (!dynsymOff || dynsymLink >= shnum)
        return nil;
    uint64_t ls = shoff + dynsymLink * shentsize; // .dynstr, the .dynsym's linked strtab
    uint64_t strOff = rd64(ls + 24), strSz = rd64(ls + 32);
    NSString* (^str)(uint64_t) = ^NSString*(uint64_t off) {
      if (off >= strSz)
          return @"";
      uint64_t e = strOff + off;
      uint64_t m = strOff + strSz;
      uint64_t n = e;
      while (n < m && b[n])
          n++;
      return [[NSString alloc] initWithBytes:b + e length:n - e encoding:NSUTF8StringEncoding] ?: @"";
    };

    NSMutableArray<NSString*>* undef = [NSMutableArray array];
    for (uint64_t o = dynsymOff; o + 24 <= dynsymOff + dynsymSz && o + 24 <= d.length; o += 24)
        {
        uint32_t stName = rd32(o);
        uint8_t stInfo = b[o + 4];
        uint16_t stShndx = rd16(o + 6);
        uint8_t bind = stInfo >> 4;
        if (stShndx == 0 /*SHN_UNDEF*/ && stName &&
            (bind == STB_GLOBAL || bind == STB_WEAK))
            {
            NSString* n = str(stName);
            if (n.length)
                [undef addObject:n];
            }
        }

    NSString* soname = path.lastPathComponent;
    for (uint64_t o = dynamicOff; dynamicOff && o + 16 <= dynamicOff + dynamicSz && o + 16 <= d.length; o += 16)
        {
        uint64_t tag = rd64(o), val = rd64(o + 8);
        if (tag == 0 /*DT_NULL*/)
            break;
        if (tag == DT_SONAME)
            {
            NSString* n = str(val);
            if (n.length)
                soname = n;
            }
        }
    return @{@"soname" : soname, @"undefined" : undef};
    }

+ (nullable NSDictionary*)objectFromData:(NSData*)dIn
    {
    enum
        {
        SHT_PROGBITS = 1,
        SHT_SYMTAB = 2,
        SHT_NOBITS = 8,
        SHT_RELA = 4,
        SHF_WRITE = 1,
        SHF_ALLOC = 2,
        SHF_EXECINSTR = 4
        };
    NSData* d = dIn;
    if (d.length < EHDR_SZ)
        return nil;
    const uint8_t* b = d.bytes;
    if (memcmp(b, "\x7f"
                  "ELF",
               4) != 0 ||
        b[4] != 2 || b[5] != 1)
        return nil; // ELF64 LE
    uint16_t (^rd16)(uint64_t) = ^uint16_t(uint64_t o) {
      return (uint16_t)(b[o] | (b[o + 1] << 8));
    };
    uint32_t (^rd32)(uint64_t) = ^uint32_t(uint64_t o) {
      return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | ((uint32_t)b[o + 3] << 24);
    };
    uint64_t (^rd64)(uint64_t) = ^uint64_t(uint64_t o) {
      uint64_t v = 0;
      for (int i = 0; i < 8; i++)
          v |= (uint64_t)b[o + i] << (8 * i);
      return v;
    };
    if (rd16(16) != 1 /*ET_REL*/)
        return nil;

    uint64_t shoff = rd64(40);
    uint16_t shentsize = rd16(58), shnum = rd16(60);
    if (!shnum || shoff + (uint64_t)shnum * shentsize > d.length)
        return nil;
    NSMutableArray<NSDictionary*>* secs = [NSMutableArray array];
    for (uint16_t i = 0; i < shnum; i++)
        {
        uint64_t s = shoff + (uint64_t)i * shentsize;
        [secs addObject:@{@"type" : @(rd32(s + 4)), @"flags" : @(rd64(s + 8)), @"off" : @(rd64(s + 24)), @"size" : @(rd64(s + 32)), @"link" : @(rd32(s + 40)), @"info" : @(rd32(s + 44)), @"align" : @(rd64(s + 48)), @"entsize" : @(rd64(s + 56))}];
        }
    uint32_t (^styp)(NSUInteger) = ^uint32_t(NSUInteger i) {
      return [secs[i][@"type"] unsignedIntValue];
    };
    uint64_t (^sflg)(NSUInteger) = ^uint64_t(NSUInteger i) {
      return [secs[i][@"flags"] unsignedLongLongValue];
    };
    uint64_t (^soff)(NSUInteger) = ^uint64_t(NSUInteger i) {
      return [secs[i][@"off"] unsignedLongLongValue];
    };
    uint64_t (^ssz)(NSUInteger) = ^uint64_t(NSUInteger i) {
      return [secs[i][@"size"] unsignedLongLongValue];
    };
    // A section's OWN alignment, floored at 1. Ignoring it is not a tidiness
    // matter: `movaps` faults outright on a 16-byte constant that landed on an
    // 8-byte boundary, and musl's .rodata.cst16 is full of them.
    uint64_t (^saln)(NSUInteger) = ^uint64_t(NSUInteger i) {
      uint64_t a = [secs[i][@"align"] unsignedLongLongValue];
      return a < 1 ? 1 : a;
    };

    // EVERY executable section is code, not just the first. A library built with
    // -ffunction-sections puts each function in its own `.text.<name>` and
    // leaves `.text` empty — so taking the first one gave a zero-length blob and
    // classified every function in the member as UNDEFINED, which is how a
    // perfectly good `atoi.lo` came back defining nothing at all. They are
    // concatenated the way the data sections already were, with each one's
    // place in the blob recorded so a symbol and a relocation can be rebased.
    NSMutableData* textBlob = [NSMutableData data];
    NSMutableDictionary<NSNumber*, NSNumber*>* textOffOf = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < secs.count; i++)
        {
        if (styp(i) != SHT_PROGBITS || !(sflg(i) & SHF_EXECINSTR))
            continue;
        uint64_t ta = saln(i) < 16 ? 16 : saln(i); // code: 16 at minimum
        while (textBlob.length % ta)
            {
            uint8_t z = 0;
            [textBlob appendBytes:&z length:1];
            }
        textOffOf[@(i)] = @(textBlob.length);
        [textBlob appendBytes:b + soff(i) length:(NSUInteger)ssz(i)];
        }
    if (!textOffOf.count)
        return nil;
    NSData* text = textBlob;

    NSMutableData* data = [NSMutableData data];
    NSMutableDictionary<NSNumber*, NSNumber*>* blobOff = [NSMutableDictionary dictionary];
    // Thread-local sections (.tdata/.tbss, SHF_TLS) are NOT data: their bytes
    // are a per-thread INITIALISATION IMAGE and their symbols' values are
    // offsets within the thread's block, not addresses. Collected into their
    // own blob (tbss as explicit zeros — the whole image is memcpy'd per
    // thread, and a few zero bytes cost nothing at these sizes).
    NSMutableData* tls = [NSMutableData data];
    NSMutableDictionary<NSNumber*, NSNumber*>* tlsOffOf = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < secs.count; i++)
        {
        if (textOffOf[@(i)])
            continue;
        if (!(sflg(i) & SHF_ALLOC))
            continue;
        if (styp(i) != SHT_PROGBITS && styp(i) != SHT_NOBITS)
            continue;
        if (sflg(i) & SHF_EXECINSTR)
            continue;
        if (sflg(i) & 0x400 /*SHF_TLS*/)
            {
            while (tls.length % (saln(i) ?: 1))
                {
                uint8_t z = 0;
                [tls appendBytes:&z length:1];
                }
            tlsOffOf[@(i)] = @(tls.length);
            if (styp(i) == SHT_NOBITS)
                [tls appendData:[NSMutableData dataWithLength:(NSUInteger)ssz(i)]];
            else
                [tls appendBytes:b + soff(i) length:(NSUInteger)ssz(i)];
            continue;
            }
        while (data.length % saln(i))
            {
            uint8_t z = 0;
            [data appendBytes:&z length:1];
            }
        blobOff[@(i)] = @(data.length);
        if (styp(i) == SHT_NOBITS)
            [data appendData:[NSMutableData dataWithLength:(NSUInteger)ssz(i)]];
        else
            [data appendBytes:b + soff(i) length:(NSUInteger)ssz(i)];
        }

    NSUInteger symIdx = 0;
    for (NSUInteger i = 1; i < secs.count; i++)
        if (styp(i) == SHT_SYMTAB)
            {
            symIdx = i;
            break;
            }
    if (!symIdx)
        return nil;
    uint64_t stroff = soff([secs[symIdx][@"link"] unsignedIntValue]);
    uint64_t nsyms = ssz(symIdx) / SYM_SZ;

    NSMutableDictionary<NSString*, NSNumber*>* syms = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* dsyms = [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* symnames = [NSMutableArray array];
    NSMutableArray<NSDictionary*>* symdefs = [NSMutableArray array];
    // A COMMON symbol is allocated into the data blob below but belongs to no
    // SECTION, so the section scan that computes `dataalign` cannot see it. Its
    // alignment has to be carried separately or an object whose data is ONLY
    // commons reports align 1 — the merge then floors that to 8, and a
    // tentative `double big[64]` (which clang aligns to 16) lands on an 8-byte
    // boundary for `movaps` to fault on. Same defect as the .rodata.cst16 one
    // the text above guards against, reached by a different route.
    uint64_t commonAlign = 1;
    for (uint64_t i = 0; i < nsyms; i++)
        {
        uint64_t e = soff(symIdx) + i * SYM_SZ;
        NSString* n = [NSString stringWithUTF8String:(const char*)(b + stroff + rd32(e))] ?: @"";
        uint8_t info = b[e + 4];
        uint16_t shndx = rd16(e + 6);
        uint64_t val = rd64(e + 8);
        BOOL ext = ((info >> 4) != 0); // STB_LOCAL is 0; anything else is visible
        int where = 0;
        uint64_t off = 0;
        if ((info & 0xF) == 6 /*STT_TLS*/ && shndx != 0 && shndx < secs.count)
            {
            // st_value of a TLS symbol is its offset within its TLS section;
            // classified FIRST or the address branch below claims (and drops) it.
            if (tlsOffOf[@(shndx)])
                {
                where = 3;
                off = tlsOffOf[@(shndx)].unsignedLongLongValue + val;
                }
            }
        else if (shndx != 0 && shndx < secs.count)
            {
            if (textOffOf[@(shndx)])
                {
                where = 1;
                off = textOffOf[@(shndx)].unsignedLongLongValue + val;
                }
            else if (blobOff[@(shndx)])
                {
                where = 2;
                off = blobOff[@(shndx)].unsignedLongLongValue + val;
                }
            }
        else if (shndx == 0xFFF2 /*SHN_COMMON*/)
            {
            // A COMMON symbol (assembler `.comm`): st_value is the ALIGNMENT and
            // st_size the byte count, and no section holds it. Record it as a BSS
            // request (where=5) with its size/align; the merge allocates one NOBITS
            // slot per name and the writer folds the zero pool onto the END of .data
            // (kept out of p_filesz). Materialising it here made a 50 MB tentative
            // global 50 MB of stored zeros. OpenSSL's cpuid module defines
            // OPENSSL_ia32cap_P this way (how a static libpq link first asked for it).
            uint64_t algn = val ? val : 8;
            uint64_t csize = rd64(e + 16);
            [symnames addObject:n];
            [symdefs addObject:@{@"ext" : @(ext), @"where" : @(5), @"off" : @(0), @"size" : @(csize ? csize : 8), @"align" : @(algn), @"weak" : @((info >> 4) == 2 /*STB_WEAK*/)}];
            continue;
            }
        [symnames addObject:n];
        [symdefs addObject:@{@"ext" : @(ext), @"where" : @(where), @"off" : @(off),
                             @"size" : @(rd64(e + 16)), // st_size: function extent (bug 196 GC)
                             @"weak" : @((info >> 4) == 2 /*STB_WEAK*/)}];
        if (n.length && ext && where == 1)
            syms[n] = @(off);
        else if (n.length && ext && where == 2)
            dsyms[n] = @(off);
        }

    // Relocations, routed by the section each RELA applies to (sh_info). A data
    // reloc's offset is section-relative, so it shifts by that section's place
    // in the concatenated blob.
    NSMutableArray<NSDictionary*>* relocs = [NSMutableArray array];
    NSMutableArray<NSDictionary*>* datarelocs = [NSMutableArray array];
    NSMutableArray<NSDictionary*>* tlsrelocs = [NSMutableArray array];
    for (NSUInteger i = 1; i < secs.count; i++)
        {
        if (styp(i) != SHT_RELA)
            continue;
        uint32_t applies = [secs[i][@"info"] unsignedIntValue];
        NSNumber* tOff = textOffOf[@(applies)];
        NSNumber* dOff = blobOff[@(applies)];
        NSNumber* lOff = tlsOffOf[@(applies)]; // .rela.tdata
        BOOL toText = (tOff != nil);
        if (!toText && !dOff && !lOff)
            continue; // e.g. .rela.eh_frame
        uint64_t base = (toText ? tOff : dOff ? dOff
                                              : lOff)
                            .unsignedLongLongValue;
        uint64_t n = ssz(i) / RELA_SZ;
        for (uint64_t r = 0; r < n; r++)
            {
            uint64_t e = soff(i) + r * RELA_SZ;
            uint64_t rinfo = rd64(e + 8);
            NSDictionary* rec = @{@"off" : @(rd64(e) + base),
                                  @"sym" : @(rinfo >> 32),
                                  @"type" : @(rinfo & 0xFFFFFFFFu),
                                  @"addend" : @((int64_t)rd64(e + 16))};
            [(toText ? relocs : dOff ? datarelocs
                                     : tlsrelocs) addObject:rec];
            }
        }
    uint64_t maxData = commonAlign;
    for (NSUInteger i = 1; i < secs.count; i++)
        if (blobOff[@(i)] && saln(i) > maxData)
            maxData = saln(i);
    uint64_t maxTls = 1;
    for (NSUInteger i = 1; i < secs.count; i++)
        if (tlsOffOf[@(i)] && saln(i) > maxTls)
            maxTls = saln(i);
    // Section starts within each blob: the linker's GC unit boundaries (bug 196).
    NSMutableArray<NSNumber*>*textsecs = [NSMutableArray array], *datasecs = [NSMutableArray array];
    for (NSNumber* k in textOffOf)
        [textsecs addObject:textOffOf[k]];
    for (NSNumber* k in blobOff)
        [datasecs addObject:blobOff[k]];
    return @{@"text" : text, @"data" : data, @"symbols" : syms, @"datasyms" : dsyms, @"textsecs" : textsecs, @"datasecs" : datasecs, @"symnames" : symnames, @"symdefs" : symdefs, @"relocs" : relocs, @"datarelocs" : datarelocs, @"tlsrelocs" : tlsrelocs, @"tls" : tls, @"tlsalign" : @(maxTls), @"dataalign" : @(maxData)};
    }

+ (nullable NSData*)staticExecutableFromText:(NSData*)textIn
                                        data:(NSData*)dataIn
                                     symbols:(NSDictionary<NSString*, NSNumber*>*)symbolsIn
                                 dataSymbols:(NSSet<NSString*>*)dataSymbols
                                  absSymbols:(nullable NSSet<NSString*>*)absSymbols
                                      fixups:(NSArray<XAX86_64Fixup*>*)fixups
                                 entrySymbol:(NSString*)entrySymbol
                                         bss:(nullable NSData*)bss
                                  bssSymbols:(nullable NSArray<NSString*>*)bssSyms
                                    bssAlign:(uint64_t)bssAlign
                                       error:(NSError**)error
    {
    NSMutableDictionary<NSString*, NSNumber*>* symbols = [symbolsIn mutableCopy];
    NSNumber* entry = symbols[entrySymbol];
    if (!entry || [dataSymbols containsObject:entrySymbol])
        {
        if (error)
            *error = elfErr(@"entry symbol '%@' is not defined in __text", entrySymbol);
        return nil;
        }
    NSMutableData* text = [textIn mutableCopy];
    NSMutableData* data = [dataIn mutableCopy];

    // ── link-time GOT ──
    // A GOTPCREL (type 9) reads its GOT slot's 8 bytes as DATA — libpq carries
    // a `cmpq $0, sym@GOTPCREL(%rip)` weak-symbol check and two SSE loads of
    // slot contents — so mov→lea relaxation cannot apply. Give each such
    // symbol a real slot: 8 bytes appended to DATA holding the symbol's
    // absolute address (a static, non-PIE image needs no runtime relocation
    // for that), and resolve the displacement slot-relative. A GOTPCRELX whose
    // opcode is not the relaxable mov takes a slot too, instead of erroring.
    // First-seen order keeps the layout deterministic; the selfhost writer
    // mirrors it byte for byte.
    NSMutableDictionary<NSString*, NSNumber*>* gotSlot = [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* gotOrder = [NSMutableArray array];
        {
        const uint8_t* tp0 = text.bytes;
        for (XAX86_64Fixup* f in fixups)
            {
            BOOL wants = (f.kind == XAX86FixupGotRef) || (f.kind == XAX86FixupGotLoad && (f.offset < 2 || f.offset > text.length || tp0[f.offset - 2] != 0x8b));
            if (!wants || gotSlot[f.symbol])
                continue;
            gotSlot[f.symbol] = @(0); // placeholder; offsets assigned below
            [gotOrder addObject:f.symbol];
            }
        if (gotOrder.count)
            {
            while (data.length % 8)
                {
                uint8_t z = 0;
                [data appendBytes:&z length:1];
                }
            for (NSString* sym in gotOrder)
                {
                gotSlot[sym] = @(data.length);
                uint8_t zero[8] = {0};
                [data appendBytes:zero length:8];
                }
            }
        }

    // Fold COMMON (NOBITS) storage onto the END of data, AFTER the GOT, so its
    // trailing zeros stay trailing and fileSizeOf keeps them out of p_filesz.
    // bss syms were classified as data syms; rebase from bss-relative here.
    if (bss.length)
        {
        uint64_t bal = bssAlign < 8 ? 8 : bssAlign;
        while (data.length % bal)
            {
            uint8_t z = 0;
            [data appendBytes:&z length:1];
            }
        uint64_t bbase = data.length;
        for (NSString* bnm in bssSyms)
            {
            NSNumber* bo = symbols[bnm];
            if (bo)
                symbols[bnm] = @(bbase + bo.unsignedLongLongValue);
            }
        [data appendData:bss];
        }

    // Section bases. Both are known up front (the layout doesn't depend on the
    // fixups), so a single resolution pass suffices.
    BOOL hasData = data.length > 0;
    uint64_t textAddr = ELF_VBASE + textOffsetFor(phdrCountFor(hasData));
    uint64_t dataAddr = ELF_VBASE + dataOffsetFor(hasData, text.length) + ELF_PAGE;

    uint8_t *tp = text.mutableBytes, *dp = data.mutableBytes;
    // TPOFF32 first: pre-resolved by the linker main (the addend IS the final
    // %fs-relative offset), so there is no symbol to look up.
    for (XAX86_64Fixup* f in fixups)
        {
        if (f.kind != XAX86FixupTpoff32)
            continue;
        if (f.offset + 4 > text.length)
            {
            if (error)
                *error = elfErr(@"tpoff fixup past end of text");
            return nil;
            }
        for (int i = 0; i < 4; i++)
            tp[f.offset + i] = (uint8_t)((uint64_t)f.addend >> (8 * i));
        }
    // Fill the GOT slots with the symbols' absolute addresses.
    for (NSString* sym in gotOrder)
        {
        NSNumber* off = symbols[sym];
        if (!off)
            {
            if (error)
                *error = elfErr(@"undefined symbol '%@' (a static link resolves "
                                @"everything in-house — is the runtime missing?)",
                                sym);
            return nil;
            }
        uint64_t v = [absSymbols containsObject:sym]
                         ? off.unsignedLongLongValue
                         : ([dataSymbols containsObject:sym] ? dataAddr : textAddr) + off.unsignedLongLongValue;
        NSUInteger so = gotSlot[sym].unsignedIntegerValue;
        for (int i = 0; i < 8; i++)
            dp[so + i] = (uint8_t)(v >> (8 * i));
        }
    for (XAX86_64Fixup* f in fixups)
        {
        if (f.kind == XAX86FixupTpoff32)
            continue; // patched above
        NSNumber* off = symbols[f.symbol];
        if (!off)
            {
            if (error)
                *error = elfErr(@"undefined symbol '%@' (a static link resolves "
                                @"everything in-house — is the runtime missing?)",
                                f.symbol);
            return nil;
            }
        BOOL inData = [dataSymbols containsObject:f.symbol];
        uint64_t target = [absSymbols containsObject:f.symbol]
                              ? off.unsignedLongLongValue
                              : (inData ? dataAddr : textAddr) + off.unsignedLongLongValue;

        // .quad <symbol>, in data
        if (f.kind == XAX86FixupAbs64)
            {
            if (f.offset + 8 > data.length)
                {
                if (error)
                    *error = elfErr(@"abs64 fixup for '%@' past end of data", f.symbol);
                return nil;
                }
            uint64_t v = target + (uint64_t)f.addend;
            for (int i = 0; i < 8; i++)
                dp[f.offset + i] = (uint8_t)(v >> (8 * i));
            continue;
            }
        // a PC-relative slot in data
        if (f.kind == XAX86FixupPC32Data)
            {
            if (f.offset + 4 > data.length)
                {
                if (error)
                    *error = elfErr(@"pc32 fixup for '%@' past end of data", f.symbol);
                return nil;
                }
            int64_t drel = (int64_t)target - (int64_t)(dataAddr + f.offset) + f.addend;
            if (drel < INT32_MIN || drel > INT32_MAX)
                {
                if (error)
                    *error = elfErr(@"'%@' is %lld bytes away — out of rel32 range",
                                    f.symbol, (long long)drel);
                return nil;
                }
            for (int i = 0; i < 4; i++)
                dp[f.offset + i] = (uint8_t)((uint64_t)drel >> (8 * i));
            continue;
            }
        // Rel32 / PC32, both in text and both measured from the fixup field.
        if (f.offset + 4 > text.length)
            {
            if (error)
                *error = elfErr(@"pc32 fixup for '%@' past end of text", f.symbol);
            return nil;
            }
        // GOTPCRELX (finding #17): a relaxable GOT load — the mov opcode two
        // bytes before the displacement (0x8b) becomes lea (0x8d) and the
        // displacement takes S + A - P directly. A non-mov GotLoad, and every
        // GotRef (plain GOTPCREL, type 9), resolves against its link-time GOT
        // slot instead: the slot holds the address, the field takes G + A - P.
        if (f.kind == XAX86FixupGotLoad && f.offset >= 2 && tp[f.offset - 2] == 0x8b)
            {
            tp[f.offset - 2] = 0x8d; // mov → lea
            }
        else if (f.kind == XAX86FixupGotLoad || f.kind == XAX86FixupGotRef)
            {
            NSNumber* g = gotSlot[f.symbol];
            // unreachable by construction; refuse rather than mis-patch
            if (!g)
                {
                if (error)
                    *error = elfErr(@"no GOT slot for '%@'", f.symbol);
                return nil;
                }
            target = dataAddr + g.unsignedLongLongValue;
            }
        int64_t rel = (int64_t)target - (int64_t)(textAddr + f.offset) + f.addend;
        if (rel < INT32_MIN || rel > INT32_MAX)
            {
            if (error)
                *error = elfErr(@"'%@' is %lld bytes away — out of rel32 range",
                                f.symbol, (long long)rel);
            return nil;
            }
        for (int i = 0; i < 4; i++)
            tp[f.offset + i] = (uint8_t)((uint64_t)rel >> (8 * i));
        }
    return [self execFromText:text
                  entryOffset:entry.unsignedLongLongValue
                         data:data
                      symbols:symbols
                  dataSymbols:dataSymbols];
    }

+ (nullable NSData*)sharedObjectFromText:(NSData*)textIn
                                    data:(NSData*)dataIn
                                 symbols:(NSDictionary<NSString*, NSNumber*>*)symbolsIn
                             dataSymbols:(NSSet<NSString*>*)dataSymbols
                           globalSymbols:(NSSet<NSString*>*)globalSymbols
                                  fixups:(NSArray<XAX86_64Fixup*>*)fixups
                                  soname:(NSString*)soname
                                  needed:(NSArray<NSString*>*)needed
                             entrySymbol:(NSString*)entrySymbol
                                 runpath:(NSString*)runpath
                                   iface:(NSData*)iface
                                     bss:(nullable NSData*)bss
                              bssSymbols:(nullable NSArray<NSString*>*)bssSyms
                                bssAlign:(uint64_t)bssAlign
                                   error:(NSError**)error
    {
    NSMutableDictionary<NSString*, NSNumber*>* symbols = [symbolsIn mutableCopy];
    // A dynamically-linked executable is this same file plus an entry point and
    // a PT_INTERP naming the loader — the kernel maps us, then hands control to
    // ld.so, which processes exactly the PT_DYNAMIC we already emit.
    static const char* kInterp = "/lib64/ld-linux-x86-64.so.2";
    BOOL isExec = (entrySymbol != nil);
    if (isExec && (!symbols[entrySymbol] || [dataSymbols containsObject:entrySymbol]))
        {
        if (error)
            *error = elfErr(@"entry symbol '%@' is not defined in __text", entrySymbol);
        return nil;
        }
    // ── 1. what do we import? ──
    // Anything a fixup names that this unit doesn't define. A call (Rel32)
    // import is reached through a PLT-style thunk; a DATA import — a GOTPCREL[X]
    // load of another object's exported symbol, e.g. a library's `<Class>$vtbl`
    // — is reached by pointing the load's own displacement at a GOT slot the
    // loader fills. Both take a GOT slot + a GLOB_DAT; only the call import also
    // needs a thunk. Anything else undefined (a bare abs64/pc32 to a symbol we
    // do not define) still cannot be imported — that WOULD need a code rewrite.
    NSMutableArray<NSString*>* imports = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSNumber*>* importIdx = [NSMutableDictionary dictionary];
    NSMutableSet<NSString*>* dataImports = [NSMutableSet set];
    for (XAX86_64Fixup* f in fixups)
        {
        if (symbols[f.symbol])
            continue;
        BOOL isGot = (f.kind == XAX86FixupGotLoad || f.kind == XAX86FixupGotRef);
        if (f.kind != XAX86FixupRel32 && !isGot)
            {
            if (error)
                *error = elfErr(@"'%@' is an undefined DATA symbol reached without a GOT "
                                @"load; a shared object imports it only through a GOT "
                                @"indirection (this reference would need rewriting)",
                                f.symbol);
            return nil;
            }
        if (isGot)
            [dataImports addObject:f.symbol];
        if (importIdx[f.symbol])
            continue;
        importIdx[f.symbol] = @(imports.count);
        [imports addObject:f.symbol];
        }

    // ── 2. exports ──
    NSMutableArray<NSString*>* exports = [NSMutableArray array];
    for (NSString* n in [globalSymbols.allObjects sortedArrayUsingSelector:@selector(compare:)])
        if (symbols[n])
            [exports addObject:n];

    // ── 3. sizes, then addresses ──
    // Nothing here depends on an address, so the whole layout can be fixed before
    // a single byte is written.
    NSMutableData* text = [textIn mutableCopy];
    NSMutableData* data = [dataIn mutableCopy];
    // Fold COMMON (NOBITS) storage onto the END of data. Here .got/.dynamic
    // precede .data, so .data stays last and its trailing bss zeros are trimmed
    // from p_filesz below. Rebase the bss syms (classified as data syms).
    if (bss.length)
        {
        uint64_t bal = bssAlign < 8 ? 8 : bssAlign;
        while (data.length % bal)
            {
            uint8_t z = 0;
            [data appendBytes:&z length:1];
            }
        uint64_t bbase = data.length;
        for (NSString* bnm in bssSyms)
            {
            NSNumber* bo = symbols[bnm];
            if (bo)
                symbols[bnm] = @(bbase + bo.unsignedLongLongValue);
            }
        [data appendData:bss];
        }
    NSUInteger nThunk = imports.count;
    NSUInteger thunkOff = text.length;                   // thunks are appended to __text
    NSUInteger nsym = 1 + exports.count + imports.count; // index 0 is the null symbol

    NSMutableData* dynstr = [NSMutableData data];
    NSMutableDictionary<NSString*, NSNumber*>* strOff = [NSMutableDictionary dictionary];
    uint8_t zero = 0;
    [dynstr appendBytes:&zero length:1]; // index 0 = ""
    uint32_t (^intern)(NSString*) = ^uint32_t(NSString* s) {
      NSNumber* e = strOff[s];
      if (e)
          return e.unsignedIntValue;
      uint32_t off = (uint32_t)dynstr.length;
      strOff[s] = @(off);
      [dynstr appendData:[s dataUsingEncoding:NSUTF8StringEncoding]];
      [dynstr appendBytes:&zero length:1];
      return off;
    };
    NSMutableArray<NSString*>* symOrder = [NSMutableArray arrayWithObject:@""];
    [symOrder addObjectsFromArray:exports];
    [symOrder addObjectsFromArray:imports];
    for (NSUInteger i = 1; i < symOrder.count; i++)
        intern(symOrder[i]);
    uint32_t sonameOff = intern(soname);
    NSMutableArray<NSNumber*>* neededOff = [NSMutableArray array];
    for (NSString* n in needed ?: @[])
        [neededOff addObject:@(intern(n))];
    uint32_t runpathOff = runpath.length ? intern(runpath) : 0;

    NSUInteger nbucket = nsym < 4 ? 1 : nsym / 4 + 1;
    NSUInteger hashSz = (2 + nbucket + nsym) * 4;
    NSUInteger nDyn = 8 + (isExec ? 0 : 1) + (runpath.length ? 1 : 0) + neededOff.count + 1; // tags below, NEEDEDs, NULL

    // Relocations: one RELATIVE per .quad-of-a-local-symbol, one GLOB_DAT per import.
    // Only Abs64 needs a dynamic reloc (an absolute pointer the loader must
    // bias). A PC32Data slot — a compiler's own .rodata jump table, `.long
    // target - table_base` — is a difference of two in-image addresses, so it is
    // invariant under the load bias and is resolved at link time with NO dynamic
    // relocation. (It was being lumped with Abs64 here, which emitted an 8-byte
    // RELATIVE reloc over a 4-byte slot and left the jump table zero — every
    // `switch` in bundled C then dispatched through a null table entry.)
    NSMutableArray<XAX86_64Fixup*>* absFixups = [NSMutableArray array];
    for (XAX86_64Fixup* f in fixups)
        if (f.kind == XAX86FixupAbs64)
            [absFixups addObject:f];
    NSUInteger nRela = absFixups.count + imports.count;

    // A library needs R, RX, RW, DYNAMIC, GNU_STACK. An executable adds PT_PHDR
    // and PT_INTERP — and PT_PHDR is not optional: ld.so locates the main
    // executable's program headers through it, and without one it walks garbage
    // and dies before it can even print an LD_DEBUG line.
    uint32_t nphdr = isExec ? 7 : 5;
    uint64_t interpOff = roundUpTo(EHDR_SZ + (uint64_t)nphdr * PHDR_SZ, 8);
    uint64_t interpSz = isExec ? strlen(kInterp) + 1 : 0;
    uint64_t roOff = roundUpTo(interpOff + interpSz, 8);
    uint64_t symOff = roOff;
    uint64_t strOffB = symOff + nsym * SYM_SZ;
    uint64_t hashOff = roundUpTo(strOffB + dynstr.length, 8);
    uint64_t relaOff = hashOff + hashSz;
    uint64_t roEnd = relaOff + nRela * RELA_SZ;

    uint64_t textOff = roundUpTo(roEnd, ELF_PAGE) + ELF_PAGE; // own RX mapping
    uint64_t textLen = text.length + nThunk * THUNK_SZ;
    // .got and .dynamic come BEFORE .data in the RW segment so that .data is
    // last and its trailing zeros can be left out of the file (p_memsz >
    // p_filesz, kernel zero-fills). With .data first they would be interior
    // bytes and every zero would have to be stored.
    uint64_t rwOff = roundUpTo(textOff + textLen, ELF_PAGE) + ELF_PAGE;
    uint64_t gotOff = rwOff;
    uint64_t dynOff = gotOff + imports.count * 8;
    uint64_t dataAddr = roundUpTo(dynOff + nDyn * DYN_SZ, 16);
    uint64_t rwEnd = dataAddr + data.length; // memsz end
    // rwFileEnd / dataFileSz are set below, AFTER the fixup loop patches data —
    // a vtable slot holding a symbolic .quad is zero until its abs64 fixup runs,
    // and measuring the trailing-zero run before that would drop the slot from
    // the file, so the virtual call reads null.

    // ET_DYN vaddrs are file-relative: the loader picks the base and adds it.
    uint64_t textAddr = textOff, thunkAddr = textOff + thunkOff;

    // ── 4. thunks ──
    for (NSUInteger i = 0; i < imports.count; i++)
        {
        uint64_t here = thunkAddr + i * THUNK_SZ;
        int64_t rel = (int64_t)(gotOff + i * 8) - (int64_t)(here + THUNK_SZ);
        put8v(text, 0xFF);
        put8v(text, 0x25); // jmp qword ptr [rip + disp32]
        put32v(text, (uint32_t)(int32_t)rel);
        }

    // ── 5. resolve the text/data fixups ──
    uint8_t *tp = text.mutableBytes, *dp = data.mutableBytes;
    for (XAX86_64Fixup* f in fixups)
        {
        NSNumber* off = symbols[f.symbol];
        BOOL isGot = (f.kind == XAX86FixupGotLoad || f.kind == XAX86FixupGotRef);
        uint64_t target;
        if (off)
            target = ([dataSymbols containsObject:f.symbol] ? dataAddr : textAddr) + off.unsignedLongLongValue;
        // A GOT-based reference to an IMPORT resolves to that import's GOT slot
        // (loader-filled via GLOB_DAT); a call import resolves to its thunk.
        else if (isGot)
            target = gotOff + importIdx[f.symbol].unsignedIntegerValue * 8;
        else
            target = thunkAddr + importIdx[f.symbol].unsignedIntegerValue * THUNK_SZ;

        if (f.kind == XAX86FixupAbs64)
            {
            // Filled with the link-time address; the RELATIVE relocation makes the
            // loader add the load bias on top.
            if (f.offset + 8 > data.length)
                {
                if (error)
                    *error = elfErr(@"abs64 fixup for '%@' past end of data", f.symbol);
                return nil;
                }
            uint64_t v = target + (uint64_t)f.addend;
            for (int i = 0; i < 8; i++)
                dp[f.offset + i] = (uint8_t)(v >> (8 * i));
            continue;
            }
        // a PC-relative slot in DATA
        if (f.kind == XAX86FixupPC32Data)
            {
            // e.g. a `.rodata` jump table: `.long case - table_base`. Both ends
            // are in the image, so S + A - P is a link-time constant (patch the
            // data buffer, not text) and needs no dynamic relocation.
            if (f.offset + 4 > data.length)
                {
                if (error)
                    *error = elfErr(@"pc32 fixup for '%@' past end of data", f.symbol);
                return nil;
                }
            int64_t drel = (int64_t)target - (int64_t)(dataAddr + f.offset) + f.addend;
            if (drel < INT32_MIN || drel > INT32_MAX)
                {
                if (error)
                    *error = elfErr(@"'%@' is %lld bytes away — out of rel32 range",
                                    f.symbol, (long long)drel);
                return nil;
                }
            for (int i = 0; i < 4; i++)
                dp[f.offset + i] = (uint8_t)((uint64_t)drel >> (8 * i));
            continue;
            }
        if (f.offset + 4 > text.length)
            {
            if (error)
                *error = elfErr(@"pc32 fixup for '%@' past end of text", f.symbol);
            return nil;
            }
        // A GOTPCRELX to a symbol we DEFINE has no GOT slot — relax mov→lea and
        // resolve S+A-P, as the static path does. A GOT reference to an IMPORT
        // instead keeps the load: its displacement points at the loader-filled
        // GOT slot (target, above), so it must NOT be relaxed.
        if (f.kind == XAX86FixupGotLoad && off)
            {
            if (f.offset < 2 || tp[f.offset - 2] != 0x8b)
                {
                if (error)
                    *error = elfErr(@"GOTPCRELX for '%@' is not a relaxable mov "
                                    @"(opcode 0x%02x) — only the mov→lea "
                                    @"relaxation is implemented",
                                    f.symbol,
                                    f.offset >= 2 ? tp[f.offset - 2] : 0);
                return nil;
                }
            tp[f.offset - 2] = 0x8d; // mov → lea
            }
        int64_t rel = (int64_t)target - (int64_t)(textAddr + f.offset) + f.addend;
        if (rel < INT32_MIN || rel > INT32_MAX)
            {
            if (error)
                *error = elfErr(@"'%@' is %lld bytes away — out of rel32 range",
                                f.symbol, (long long)rel);
            return nil;
            }
        for (int i = 0; i < 4; i++)
            tp[f.offset + i] = (uint8_t)((uint64_t)rel >> (8 * i));
        }
    uint64_t dataFileSz = fileSizeOf(data);
    uint64_t rwFileEnd = dataAddr + dataFileSz;

    // ── 6. build the file ──
    NSMutableData* out = [NSMutableData data];
    put8v(out, 0x7f);
    put8v(out, 'E');
    put8v(out, 'L');
    put8v(out, 'F');
    put8v(out, 2);
    put8v(out, 1);
    put8v(out, 1);
    put8v(out, 0);
    put8v(out, 0);
    for (int i = 0; i < 7; i++)
        put8v(out, 0);
    put16v(out, ET_DYN);
    put16v(out, EM_X86_64);
    put32v(out, 1);
    // e_entry is patched in below once textAddr is known; a library keeps 0.
    put64v(out, 0);
    put64v(out, EHDR_SZ);
    put64v(out, 0);       // e_shoff: no section headers.
    put32v(out, 0);       //   ld.so reads program headers
    put16v(out, EHDR_SZ); //   only; `readelf -S` will
    put16v(out, PHDR_SZ); //   show nothing.
    put16v(out, (uint16_t)nphdr);
    put16v(out, 64);
    put16v(out, 0);
    put16v(out, 0);

    void (^phdr)(uint32_t, uint32_t, uint64_t, uint64_t, uint64_t) =
        ^(uint32_t type, uint32_t flags, uint64_t off, uint64_t sz, uint64_t align) {
          put32v(out, type);
          put32v(out, flags);
          put64v(out, off);
          put64v(out, off);
          put64v(out, off); // vaddr == offset
          put64v(out, sz);
          put64v(out, sz);
          put64v(out, align);
        };
    if (isExec)
        {
        // Both must come before the loadable segments, and both must fall inside
        // one — the first PT_LOAD below starts at offset 0 and covers them.
        phdr(PT_PHDR, PF_R, EHDR_SZ, (uint64_t)nphdr * PHDR_SZ, 8);
        phdr(PT_INTERP, PF_R, interpOff, interpSz, 1);
        }
    phdr(PT_LOAD, PF_R, 0, roEnd, ELF_PAGE);
    phdr(PT_LOAD, PF_R | PF_X, textOff, textLen, ELF_PAGE);
    // Emitted by hand rather than through phdr(): this is the one segment whose
    // file and memory sizes differ.
    put32v(out, PT_LOAD);
    put32v(out, PF_R | PF_W);
    put64v(out, rwOff);
    put64v(out, rwOff);
    put64v(out, rwOff);
    put64v(out, rwFileEnd - rwOff); // p_filesz
    put64v(out, rwEnd - rwOff);     // p_memsz
    put64v(out, ELF_PAGE);
    phdr(PT_DYNAMIC, PF_R | PF_W, dynOff, nDyn * DYN_SZ, 8);
    // Without this the loader assumes the library wants an executable stack and
    // refuses to map it ("cannot enable executable stack as shared object
    // requires"). Present, with no PF_X, it asks for the opposite.
    put32v(out, PT_GNU_STACK);
    put32v(out, PF_R | PF_W);
    put64v(out, 0);
    put64v(out, 0);
    put64v(out, 0);
    put64v(out, 0);
    put64v(out, 0);
    put64v(out, 0x10);

    if (isExec)
        {
        while (out.length < interpOff)
            put8v(out, 0);
        [out appendBytes:kInterp length:interpSz];
        }
    while (out.length < symOff)
        put8v(out, 0);
    for (NSUInteger i = 0; i < symOrder.count; i++)
        {
        NSString* n = symOrder[i];
        BOOL isNull = (i == 0);
        NSNumber* off = isNull ? nil : symbols[n];
        // A defined data symbol, or an UNDEFINED data import (a GOT-loaded
        // `<Class>$vtbl` from another object), is STT_OBJECT; everything else is
        // a function. The type is advisory for GLOB_DAT binding but keeps `nm`
        // and the loader's diagnostics honest.
        BOOL inData = off ? [dataSymbols containsObject:n]
                          : (!isNull && [dataImports containsObject:n]);
        put32v(out, isNull ? 0 : intern(n)); // st_name
        put8v(out, isNull ? 0 : (uint8_t)((STB_GLOBAL << 4) | (inData ? STT_OBJECT : STT_FUNC)));
        put8v(out, 0);                         // st_other
        put16v(out, (isNull || !off) ? 0 : 1); // st_shndx: 0 = undefined
        put64v(out, off ? (inData ? dataAddr : textAddr) + off.unsignedLongLongValue : 0);
        put64v(out, 0); // st_size — unknown, unused
        }
    while (out.length < strOffB)
        put8v(out, 0);
    [out appendData:dynstr];

    while (out.length < hashOff)
        put8v(out, 0);
        {
        uint32_t *bucket = calloc(nbucket, 4), *chain = calloc(nsym, 4);
        for (NSUInteger i = 1; i < symOrder.count; i++)
            {
            uint32_t b = elfHash(symOrder[i].UTF8String) % (uint32_t)nbucket;
            chain[i] = bucket[b]; // push onto the chain
            bucket[b] = (uint32_t)i;
            }
        put32v(out, (uint32_t)nbucket);
        put32v(out, (uint32_t)nsym);
        for (NSUInteger i = 0; i < nbucket; i++)
            put32v(out, bucket[i]);
        for (NSUInteger i = 0; i < nsym; i++)
            put32v(out, chain[i]);
        free(bucket);
        free(chain);
        }

    while (out.length < relaOff)
        put8v(out, 0);
    // R_X86_64_RELATIVE
    for (XAX86_64Fixup* f in absFixups)
        {
        NSNumber* off = symbols[f.symbol];
        uint64_t target = ([dataSymbols containsObject:f.symbol] ? dataAddr : textAddr) + off.unsignedLongLongValue + (uint64_t)f.addend;
        put64v(out, dataAddr + f.offset);
        put64v(out, R_X86_64_RELATIVE);
        put64v(out, target);
        }
    // R_X86_64_GLOB_DAT
    for (NSUInteger i = 0; i < imports.count; i++)
        {
        uint64_t symIdx = 1 + exports.count + i;
        put64v(out, gotOff + i * 8);
        put64v(out, (symIdx << 32) | R_X86_64_GLOB_DAT);
        put64v(out, 0);
        }

    while (out.length < textOff)
        put8v(out, 0);
    [out appendData:text];
    while (out.length < gotOff)
        put8v(out, 0);
    for (NSUInteger i = 0; i < imports.count; i++)
        put64v(out, 0); // filled by ld.so

    while (out.length < dynOff)
        put8v(out, 0);
    void (^dyn)(uint64_t, uint64_t) = ^(uint64_t tag, uint64_t val) {
      put64v(out, tag);
      put64v(out, val);
    };
    for (NSNumber* n in neededOff)
        dyn(DT_NEEDED, n.unsignedIntValue);
    // DT_SONAME names a LIBRARY. On an executable ld.so still records it, and an
    // executable claiming to be a library confuses the lookup scope.
    if (!isExec)
        dyn(DT_SONAME, sonameOff);
    // DT_RUNPATH rather than the deprecated DT_RPATH: it applies only to this
    // object's own DT_NEEDEDs, which is what "find the library beside me" means.
    if (runpath.length)
        dyn(DT_RUNPATH, runpathOff);
    dyn(DT_HASH, hashOff);
    dyn(DT_STRTAB, strOffB);
    dyn(DT_SYMTAB, symOff);
    dyn(DT_STRSZ, dynstr.length);
    dyn(DT_SYMENT, SYM_SZ);
    dyn(DT_RELA, relaOff);
    dyn(DT_RELASZ, nRela * RELA_SZ);
    dyn(DT_RELAENT, RELA_SZ);
    dyn(DT_NULL, 0);

    // .data last in the RW segment, and only the bytes that are not trailing zeros.
    while (out.length < dataAddr)
        put8v(out, 0);
    [out appendData:[data subdataWithRange:NSMakeRange(0, (NSUInteger)dataFileSz)]];

    // ── section headers ──
    // ld.so reads program headers only and never looks at these, but without
    // them `readelf -S`, `nm` and gdb see an object with no sections at all.
    // They cost a few hundred bytes at the end of the file.
    //
    // The table is built as a LIST rather than a fixed sequence: e_shnum and
    // e_shstrndx have to agree with it exactly, and hardcoding them meant
    // touching three places every time a section became conditional.
    enum
        {
        SHT_PROGBITS = 1,
        SHT_SYMTAB = 2,
        SHT_STRTAB = 3,
        SHT_RELA = 4,
        SHT_HASH = 5,
        SHT_DYNAMIC = 6,
        SHT_DYNSYM = 11,
        SHF_WRITE = 1,
        SHF_ALLOC = 2,
        SHF_EXECINSTR = 4
        };

    // .symtab lists every defined symbol, not just the exported ones .dynsym
    // carries — the difference between `nm` showing an API and showing the
    // internals you actually need when something faults inside the library.
    // .text and .data are at these indices in the section list built below; the
    // symbols' st_shndx must name them, so the two are declared together rather
    // than left as bare numbers in two places that have to be kept in step.
    const uint16_t kTextSecIdx = 5, kDataSecIdx = 6;

    NSMutableData* strtab = [NSMutableData data];
    put8v(strtab, 0);
    NSMutableData* symtab = [NSMutableData data];
    for (int i = 0; i < SYM_SZ; i++)
        put8v(symtab, 0); // the null symbol
    for (NSString* n in [symbols.allKeys sortedArrayUsingSelector:@selector(compare:)])
        {
        BOOL inData = [dataSymbols containsObject:n];
        put32v(symtab, (uint32_t)strtab.length);
        [strtab appendData:[n dataUsingEncoding:NSUTF8StringEncoding]];
        put8v(strtab, 0);
        put8v(symtab, (uint8_t)((STB_GLOBAL << 4) | (inData ? STT_OBJECT : STT_FUNC)));
        put8v(symtab, 0);
        put16v(symtab, inData ? kDataSecIdx : kTextSecIdx);
        put64v(symtab, (inData ? dataAddr : textAddr) + symbols[n].unsignedLongLongValue);
        put64v(symtab, 0);
        }

    // name, type, flags, offset, size, link, info, align, entsize — link fields
    // are section INDICES, so they follow this order.
    NSMutableArray<NSArray*>* secs = [NSMutableArray array];
    void (^sec)(NSString*, uint32_t, uint64_t, uint64_t, uint64_t,
                uint32_t, uint32_t, uint64_t, uint64_t) =
        ^(NSString* nm, uint32_t type, uint64_t flags, uint64_t off, uint64_t size,
          uint32_t link, uint32_t info, uint64_t align, uint64_t entsz) {
          [secs addObject:@[ nm ?: @"", @(type), @(flags), @(off), @(size),
                             @(link), @(info), @(align), @(entsz) ]];
        };
    sec(nil, 0, 0, 0, 0, 0, 0, 0, 0); // 0
    // sh_link of .dynsym is its string table; sh_info the first global index —
    // every symbol we export is global, so that is 1.
    sec(@".dynsym", SHT_DYNSYM, SHF_ALLOC, symOff, nsym * SYM_SZ, 2, 1, 8, SYM_SZ);     // 1
    sec(@".dynstr", SHT_STRTAB, SHF_ALLOC, strOffB, dynstr.length, 0, 0, 1, 0);         // 2
    sec(@".hash", SHT_HASH, SHF_ALLOC, hashOff, hashSz, 1, 0, 8, 4);                    // 3
    sec(@".rela.dyn", SHT_RELA, SHF_ALLOC, relaOff, nRela * RELA_SZ, 1, 0, 8, RELA_SZ); // 4
    NSAssert(secs.count == kTextSecIdx, @"kTextSecIdx is out of step with the section list");
    sec(@".text", SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR, textOff, textLen, 0, 0, 16, 0);
    NSAssert(secs.count == kDataSecIdx, @"kDataSecIdx is out of step with the section list");
    sec(@".data", SHT_PROGBITS, SHF_ALLOC | SHF_WRITE, dataAddr, data.length, 0, 0, 16, 0);
    sec(@".got", SHT_PROGBITS, SHF_ALLOC | SHF_WRITE, gotOff, imports.count * 8, 0, 0, 8, 8);
    sec(@".dynamic", SHT_DYNAMIC, SHF_ALLOC | SHF_WRITE, dynOff, nDyn * DYN_SZ, 2, 0, 8, DYN_SZ);
    NSUInteger symtabIdx = secs.count, strtabIdx = symtabIdx + 1;
    sec(@".symtab", SHT_SYMTAB, 0, 0, symtab.length, (uint32_t)strtabIdx, 1, 8, SYM_SZ);
    sec(@".strtab", SHT_STRTAB, 0, 0, strtab.length, 0, 0, 1, 0);
    NSUInteger ifaceIdx = 0;
    if (iface.length)
        {
        ifaceIdx = secs.count;
        sec(@".xtc.iface", SHT_PROGBITS, 0, 0, iface.length, 0, 0, 1, 0);
        }
    NSUInteger shstrIdx = secs.count;
    sec(@".shstrtab", SHT_STRTAB, 0, 0, 0, 0, 0, 1, 0);

    NSMutableData* shstr = [NSMutableData data];
    put8v(shstr, 0);
    NSMutableDictionary<NSString*, NSNumber*>* shName = [NSMutableDictionary dictionary];
    for (NSArray* e in secs)
        {
        NSString* n = e[0];
        if (!n.length || shName[n])
            continue;
        shName[n] = @(shstr.length);
        [shstr appendData:[n dataUsingEncoding:NSUTF8StringEncoding]];
        put8v(shstr, 0);
        }

    // Lay the non-allocated section CONTENTS out now, then patch their offsets
    // into the records built above.
    uint64_t symtabOff = roundUpTo(out.length, 8);
    while (out.length < symtabOff)
        put8v(out, 0);
    [out appendData:symtab];
    uint64_t strtabOff = out.length;
    [out appendData:strtab];
    // The serialised module interface, verbatim. XTInterfaceImporter reads it by
    // name — without it `#import <Lib>` sees none of the library's classes and
    // the compile fails with "undefined identifier" a long way from the cause.
    uint64_t ifaceOff = out.length;
    if (iface.length)
        [out appendData:iface];
    uint64_t shstrOff = out.length;
    [out appendData:shstr];

    NSMutableArray* m = [secs[symtabIdx] mutableCopy];
    m[3] = @(symtabOff);
    secs[symtabIdx] = m;
    m = [secs[strtabIdx] mutableCopy];
    m[3] = @(strtabOff);
    secs[strtabIdx] = m;
    if (iface.length)
        {
        m = [secs[ifaceIdx] mutableCopy];
        m[3] = @(ifaceOff);
        secs[ifaceIdx] = m;
        }
    m = [secs[shstrIdx] mutableCopy];
    m[3] = @(shstrOff);
    m[4] = @(shstr.length);
    secs[shstrIdx] = m;

    uint64_t shOff = roundUpTo(out.length, 8);
    while (out.length < shOff)
        put8v(out, 0);
    for (NSArray* e in secs)
        {
        NSString* nm = e[0];
        uint64_t flags = [e[2] unsignedLongLongValue], off = [e[3] unsignedLongLongValue];
        put32v(out, nm.length ? shName[nm].unsignedIntValue : 0);
        put32v(out, [e[1] unsignedIntValue]);
        put64v(out, flags);
        // Allocated sections are mapped at vaddr == file offset, as the program
        // headers above declare; the rest sit at address 0.
        put64v(out, (flags & SHF_ALLOC) ? off : 0);
        put64v(out, off);
        put64v(out, [e[4] unsignedLongLongValue]);
        put32v(out, [e[5] unsignedIntValue]);
        put32v(out, [e[6] unsignedIntValue]);
        put64v(out, [e[7] unsignedLongLongValue]);
        put64v(out, [e[8] unsignedLongLongValue]);
        }

    uint8_t* hp = out.mutableBytes;
    if (isExec)
        {
        uint64_t e = textAddr + symbols[entrySymbol].unsignedLongLongValue;
        for (int i = 0; i < 8; i++)
            hp[0x18 + i] = (uint8_t)(e >> (8 * i)); // e_entry
        }
    for (int i = 0; i < 8; i++)
        hp[0x28 + i] = (uint8_t)(shOff >> (8 * i)); // e_shoff
    hp[0x3C] = (uint8_t)(secs.count & 0xFF);
    hp[0x3D] = (uint8_t)(secs.count >> 8);
    hp[0x3E] = (uint8_t)(shstrIdx & 0xFF);
    hp[0x3F] = (uint8_t)(shstrIdx >> 8);
    return out;
    }

+ (NSData*)staticExecutableFromText:(NSData*)text
                        entryOffset:(uint64_t)entryOffset
                               data:(NSData*)dataIn
    {
    return [self execFromText:text
                  entryOffset:entryOffset
                         data:dataIn
                      symbols:nil
                  dataSymbols:nil];
    }

// `symbols` is optional: with it the file gains a .symtab/.strtab and section
// headers, so nm, readelf and gdb backtraces work. Neither the kernel nor ld.so
// reads any of it — but debugging a fault in a stripped binary means
// disassembling by hand, which is exactly how long the sil/dil bug took to find.
+ (NSData*)execFromText:(NSData*)text
            entryOffset:(uint64_t)entryOffset
                   data:(NSData*)dataIn
                symbols:(nullable NSDictionary<NSString*, NSNumber*>*)symbols
            dataSymbols:(nullable NSSet<NSString*>*)dataSymbols
    {
    NSData* data = dataIn ?: [NSData data];
    BOOL hasData = data.length > 0;
    uint32_t nphdr = phdrCountFor(hasData);

    // ── layout ──
    // The headers share the first page with the code, so the text segment maps
    // from file offset 0 (a common, simple arrangement: p_offset and p_vaddr are
    // congruent modulo the page size, which the kernel requires).
    uint64_t textOff = textOffsetFor(nphdr);
    uint64_t textAddr = ELF_VBASE + textOff;
    uint64_t textEnd = textOff + text.length;
    // Keep p_vaddr ≡ p_offset (mod page).
    uint64_t dataOff = dataOffsetFor(hasData, text.length);
    uint64_t dataAddr = ELF_VBASE + dataOff + ELF_PAGE;
    uint64_t dataFileSz = fileSizeOf(data);

    NSMutableData* out = [NSMutableData data];

    // ── ELF header ──
    put8v(out, 0x7f);
    put8v(out, 'E');
    put8v(out, 'L');
    put8v(out, 'F');
    put8v(out, 2); // EI_CLASS   = ELFCLASS64
    put8v(out, 1); // EI_DATA    = ELFDATA2LSB
    put8v(out, 1); // EI_VERSION
    put8v(out, 0); // EI_OSABI   = SYSV
    put8v(out, 0); // EI_ABIVERSION
    for (int i = 0; i < 7; i++)
        put8v(out, 0); // EI_PAD
    put16v(out, ET_EXEC);
    put16v(out, EM_X86_64);
    put32v(out, 1);                      // e_version
    put64v(out, textAddr + entryOffset); // e_entry
    put64v(out, EHDR_SZ);                // e_phoff
    put64v(out, 0);                      // e_shoff (no section headers)
    put32v(out, 0);                      // e_flags
    put16v(out, EHDR_SZ);                // e_ehsize
    put16v(out, PHDR_SZ);                // e_phentsize
    put16v(out, (uint16_t)nphdr);        // e_phnum
    put16v(out, 64);                     // e_shentsize
    put16v(out, 0);                      // e_shnum
    put16v(out, 0);                      // e_shstrndx

    // ── program headers ──
    // 1. text (R+X), mapped from file offset 0 so it also covers the headers.
    put32v(out, PT_LOAD);
    put32v(out, PF_R | PF_X);
    put64v(out, 0);         // p_offset
    put64v(out, ELF_VBASE); // p_vaddr
    put64v(out, ELF_VBASE); // p_paddr
    put64v(out, textEnd);   // p_filesz
    put64v(out, textEnd);   // p_memsz
    put64v(out, ELF_PAGE);  // p_align

    // 2. data (R+W)
    if (hasData)
        {
        put32v(out, PT_LOAD);
        put32v(out, PF_R | PF_W);
        put64v(out, dataOff);
        put64v(out, dataAddr);
        put64v(out, dataAddr);
        put64v(out, dataFileSz);  // p_filesz — the trailing zeros are not stored
        put64v(out, data.length); // p_memsz  — the kernel zero-fills the rest
        put64v(out, ELF_PAGE);
        }

    // 3. GNU_STACK — present with no PF_X so the stack is non-executable.
    put32v(out, PT_GNU_STACK);
    put32v(out, PF_R | PF_W);
    put64v(out, 0);
    put64v(out, 0);
    put64v(out, 0);
    put64v(out, 0);
    put64v(out, 0);
    put64v(out, 0x10);

    // ── contents ──
    while (out.length < textOff)
        put8v(out, 0);
    [out appendData:text];
    if (hasData)
        {
        while (out.length < dataOff)
            put8v(out, 0);
        [out appendData:[data subdataWithRange:NSMakeRange(0, (NSUInteger)dataFileSz)]];
        }
    if (!symbols.count)
        return out;

    // ── .symtab / .strtab / .shstrtab, then the section header table ──
    enum
        {
        SHT_PROGBITS = 1,
        SHT_SYMTAB = 2,
        SHT_STRTAB = 3,
        SHF_WRITE = 1,
        SHF_ALLOC = 2,
        SHF_EXECINSTR = 4,
        SHDR_SZ = 64
        };
    NSArray<NSString*>* names =
        [symbols.allKeys sortedArrayUsingSelector:@selector(compare:)];

    // .text and .data are at these indices in the section list built below; the
    // symbols' st_shndx must name them, so the two are declared together rather
    // than left as bare numbers in two places that have to be kept in step.
    const uint16_t kTextSecIdx = 5, kDataSecIdx = 6;

    NSMutableData* strtab = [NSMutableData data];
    put8v(strtab, 0);
    NSMutableData* symtab = [NSMutableData data];
    for (int i = 0; i < 24; i++)
        put8v(symtab, 0); // index 0: the null symbol
    for (NSString* n in names)
        {
        BOOL inData = [dataSymbols containsObject:n];
        uint32_t nameOff = (uint32_t)strtab.length;
        [strtab appendData:[n dataUsingEncoding:NSUTF8StringEncoding]];
        put8v(strtab, 0);
        put32v(symtab, nameOff);
        put8v(symtab, (uint8_t)((1 << 4) | (inData ? 1 : 2))); // GLOBAL | OBJECT/FUNC
        put8v(symtab, 0);
        put16v(symtab, inData ? 2 : 1); // .data : .text
        put64v(symtab, (inData ? dataAddr : textAddr) + symbols[n].unsignedLongLongValue);
        put64v(symtab, 0);
        }

    NSMutableData* shstr = [NSMutableData data];
    put8v(shstr, 0);
    NSMutableDictionary<NSString*, NSNumber*>* shName = [NSMutableDictionary dictionary];
    for (NSString* n in @[ @".text", @".data", @".symtab", @".strtab", @".shstrtab" ])
        {
        shName[n] = @(shstr.length);
        [shstr appendData:[n dataUsingEncoding:NSUTF8StringEncoding]];
        put8v(shstr, 0);
        }

    uint64_t symOff = roundUpTo(out.length, 8);
    while (out.length < symOff)
        put8v(out, 0);
    [out appendData:symtab];
    uint64_t strOff = out.length;
    [out appendData:strtab];
    uint64_t shstrOff = out.length;
    [out appendData:shstr];
    uint64_t shOff = roundUpTo(out.length, 8);
    while (out.length < shOff)
        put8v(out, 0);

    void (^shdr)(NSString*, uint32_t, uint64_t, uint64_t, uint64_t, uint64_t,
                 uint32_t, uint32_t, uint64_t, uint64_t) =
        ^(NSString* nm, uint32_t type, uint64_t flags, uint64_t addr, uint64_t off,
          uint64_t size, uint32_t link, uint32_t info, uint64_t align, uint64_t entsz) {
          put32v(out, nm ? shName[nm].unsignedIntValue : 0);
          put32v(out, type);
          put64v(out, flags);
          put64v(out, addr);
          put64v(out, off);
          put64v(out, size);
          put32v(out, link);
          put32v(out, info);
          put64v(out, align);
          put64v(out, entsz);
        };
    shdr(nil, 0, 0, 0, 0, 0, 0, 0, 0, 0); // 0: null
    shdr(@".text", SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR, textAddr, textOff,
         text.length, 0, 0, 16, 0); // 1
    shdr(@".data", SHT_PROGBITS, SHF_ALLOC | SHF_WRITE, dataAddr, dataOff,
         data.length, 0, 0, 16, 0); // 2
    // sh_info is the index of the first non-local symbol; every symbol we emit is
    // global, so that is 1 — the entry straight after the null one.
    shdr(@".symtab", SHT_SYMTAB, 0, 0, symOff, symtab.length, 4, 1, 8, 24);   // 3
    shdr(@".strtab", SHT_STRTAB, 0, 0, strOff, strtab.length, 0, 0, 1, 0);    // 4
    shdr(@".shstrtab", SHT_STRTAB, 0, 0, shstrOff, shstr.length, 0, 0, 1, 0); // 5

    // Patch e_shoff / e_shnum / e_shstrndx, which were written as zero above.
    uint8_t* p = out.mutableBytes;
    for (int i = 0; i < 8; i++)
        p[0x28 + i] = (uint8_t)(shOff >> (8 * i));
    p[0x3C] = 6;
    p[0x3D] = 0; // e_shnum
    p[0x3E] = 5;
    p[0x3F] = 0; // e_shstrndx
    return out;
    }

@end
