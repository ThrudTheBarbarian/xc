#import "XTElfArm64Writer.h"

// ELF64 constants, written out rather than included — we do not have (or want)
// Linux/Android headers in the build.
enum
    {
    ET_DYN = 3,
    EM_AARCH64 = 183,
    PT_LOAD = 1,
    PT_DYNAMIC = 2,
    PT_INTERP = 3,
    PT_PHDR = 6,
    PT_GNU_STACK = 0x6474e551,
    PF_X = 1,
    PF_W = 2,
    PF_R = 4,
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
    DT_INIT_ARRAY = 25,
    DT_INIT_ARRAYSZ = 27,
    R_AARCH64_GLOB_DAT = 1025,
    R_AARCH64_RELATIVE = 1027,
    STB_GLOBAL = 1,
    STT_OBJECT = 1,
    STT_FUNC = 2,
    SYM_SZ = 24,
    RELA_SZ = 24,
    DYN_SZ = 16,
    SHDR_SZ = 64,
    };

// 16 KB, not 4 KB. Android 15 runs on devices with 16 KB pages, and a segment
// aligned to 4 KB will not map there; 16 KB alignment is accepted on 4 KB
// devices too, so there is one right answer and this is it.
#define ELF_PAGE 0x4000ull
#define EHDR_SZ 64
#define PHDR_SZ 56
#define THUNK_SZ 16 // adrp / ldr / br, padded to a 16-byte slot

static const char* kInterp = "/system/bin/linker64";

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

// Trailing zeros need not be stored: a PT_LOAD whose p_memsz exceeds p_filesz is
// zero-filled by the kernel, which is what .bss and a zero-initialised array are.
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
    return [NSError errorWithDomain:@"XTElfArm64Writer"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : m}];
    }

// The SysV ELF hash DT_HASH requires — specified byte-for-byte in the gABI.
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

// ── instruction-field patching ────────────────────────────────────────────
// AArch64 relocations do not overwrite whole words the way x86's disp32 does;
// each one splices a field into an already-encoded instruction. Read-modify-
// write, so the register operands the assembler chose survive.
static uint32_t insnAt(const uint8_t* p, uint64_t off)
    {
    return (uint32_t)p[off] | ((uint32_t)p[off + 1] << 8) | ((uint32_t)p[off + 2] << 16) | ((uint32_t)p[off + 3] << 24);
    }
static void setInsn(uint8_t* p, uint64_t off, uint32_t v)
    {
    for (int i = 0; i < 4; i++)
        p[off + i] = (uint8_t)(v >> (8 * i));
    }
// bl/b: imm26 = (target - pc) >> 2, signed, ±128 MB.
static BOOL patchBranch26(uint8_t* p, uint64_t off, int64_t delta, NSError** err,
                          NSString* sym)
    {
    if (delta & 3)
        {
        if (err)
            *err = elfErr(@"branch to '%@' is not 4-byte aligned", sym);
        return NO;
        }
    int64_t imm = delta >> 2;
    if (imm < -(1LL << 25) || imm >= (1LL << 25))
        {
        if (err)
            *err = elfErr(@"'%@' is %lld bytes away — out of ±128MB branch range",
                          sym, (long long)delta);
        return NO;
        }
    setInsn(p, off, (insnAt(p, off) & 0xFC000000u) | ((uint32_t)imm & 0x03FFFFFFu));
    return YES;
    }
// adrp: the 21-bit page delta splits across immlo (bits 30:29) and immhi (23:5).
static BOOL patchAdrp(uint8_t* p, uint64_t off, uint64_t target, uint64_t pc,
                      NSError** err, NSString* sym)
    {
    int64_t pages = (int64_t)(target >> 12) - (int64_t)(pc >> 12);
    if (pages < -(1LL << 20) || pages >= (1LL << 20))
        {
        if (err)
            *err = elfErr(@"'%@' is out of adrp ±4GB range", sym);
        return NO;
        }
    uint32_t v = insnAt(p, off) & 0x9F00001Fu;
    v |= (uint32_t)((pages & 0x3) << 29);           // immlo
    v |= (uint32_t)(((pages >> 2) & 0x7FFFF) << 5); // immhi
    setInsn(p, off, v);
    return YES;
    }
// add/ldr/str immediate: imm12 at bits 21:10, scaled by the access size. The
// assembler records log2(size) in the fixup; an unscaled offset is a hard error
// rather than a silently truncated one.
static BOOL patchLo12(uint8_t* p, uint64_t off, uint64_t target, uint32_t scale,
                      NSError** err, NSString* sym)
    {
    uint64_t lo = target & 0xFFF;
    if (scale && (lo & ((1u << scale) - 1)))
        {
        if (err)
            *err = elfErr(@"'%@' at +0x%llx is not %u-byte aligned, so its "
                          @"page offset cannot be encoded",
                          sym,
                          (unsigned long long)lo, 1u << scale);
        return NO;
        }
    uint32_t imm = (uint32_t)(lo >> scale);
    setInsn(p, off, (insnAt(p, off) & ~(0xFFFu << 10)) | ((imm & 0xFFFu) << 10));
    return YES;
    }

@implementation XTElfArm64Writer

+ (nullable NSData*)sharedObjectFromText:(NSData*)textIn
                                    data:(NSData*)dataIn
                                 symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                             dataSymbols:(NSSet<NSString*>*)dataSymbols
                           globalSymbols:(NSSet<NSString*>*)globalSymbols
                                  fixups:(NSArray<XAArm64Fixup*>*)fixups
                                  soname:(NSString*)soname
                                  needed:(NSArray<NSString*>*)needed
                             entrySymbol:(NSString*)entrySymbol
                           modInitLength:(NSUInteger)modInitLength
                                   error:(NSError**)error
    {
    BOOL isExec = (entrySymbol != nil);
    if (isExec && (!symbols[entrySymbol] || [dataSymbols containsObject:entrySymbol]))
        {
        if (error)
            *error = elfErr(@"entry symbol '%@' is not defined in .text", entrySymbol);
        return nil;
        }

    // ── 1. imports ────────────────────────────────────────────────────────
    // Anything a fixup names that this unit does not define. A `bl` import is
    // reached through a thunk; an adrp/add pair naming an import is reached
    // through its GOT slot directly, which only works when the pair was emitted
    // as a GOT reference (adrp/ldr) — an ABSOLUTE pair would need the ldr the
    // compiler never emitted, so it is reported rather than mislinked.
    NSMutableArray<NSString*>* imports = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSNumber*>* importIdx = [NSMutableDictionary dictionary];
    NSMutableSet<NSString*>* dataImports = [NSMutableSet set];
    for (XAArm64Fixup* f in fixups)
        {
        if (symbols[f.symbol])
            continue;
        BOOL isGot = (f.kind == XAArm64FixupGotPage21 || f.kind == XAArm64FixupGotPageOff12);
        if (f.kind != XAArm64FixupBranch26 && !isGot)
            {
            if (error)
                *error = elfErr(@"'%@' is undefined and is reached by an absolute "
                                @"reference; a dynamic image can import it only "
                                @"through a GOT indirection or a call",
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

    // ── 2. exports ────────────────────────────────────────────────────────
    NSMutableArray<NSString*>* exports = [NSMutableArray array];
    for (NSString* n in [globalSymbols.allObjects sortedArrayUsingSelector:@selector(compare:)])
        if (symbols[n])
            [exports addObject:n];

    // ── 3. sizes, then addresses ──────────────────────────────────────────
    NSMutableData* text = [textIn mutableCopy];
    NSMutableData* data = [dataIn mutableCopy];
    NSUInteger thunkOff = roundUpTo(text.length, 16); // thunks append to .text
    while (text.length < thunkOff)
        put32v(text, 0xD503201Fu);                       // nop padding
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
    uint32_t sonameOff = (!isExec && soname.length) ? intern(soname) : 0;
    NSMutableArray<NSNumber*>* neededOff = [NSMutableArray array];
    for (NSString* n in needed ?: @[])
        [neededOff addObject:@(intern(n))];

    NSUInteger nbucket = nsym < 4 ? 1 : nsym / 4 + 1;
    NSUInteger hashSz = (2 + nbucket + nsym) * 4;
    // The constructor array cannot be longer than the data it was appended to.
    NSUInteger miLen = (modInitLength <= dataIn.length) ? modInitLength : 0;
    NSUInteger nDyn = 8 + (isExec ? 0 : 1) + neededOff.count + 1 + (miLen ? 2 : 0);

    // One RELATIVE per `.quad <symbol>` — an absolute address the loader biases —
    // and one GLOB_DAT per import.
    NSMutableArray<XAArm64Fixup*>* absFixups = [NSMutableArray array];
    for (XAArm64Fixup* f in fixups)
        if (f.kind == XAArm64FixupPointer64)
            [absFixups addObject:f];
    NSUInteger nRela = absFixups.count + imports.count;

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
    uint64_t textLen = thunkOff + imports.count * THUNK_SZ;
    // .got and .dynamic precede .data in the RW segment so .data stays last and
    // its trailing zeros can be omitted from the file.
    uint64_t rwOff = roundUpTo(textOff + textLen, ELF_PAGE) + ELF_PAGE;
    uint64_t gotOff = rwOff;
    uint64_t dynOff = gotOff + imports.count * 8;
    uint64_t dataAddr = roundUpTo(dynOff + nDyn * DYN_SZ, 16);
    uint64_t rwEnd = dataAddr + data.length;

    // ET_DYN vaddrs are file-relative; the loader picks the base and adds it.
    uint64_t textAddr = textOff, thunkAddr = textOff + thunkOff;

    // ── 4. thunks ─────────────────────────────────────────────────────────
    // adrp x16, <got page> / ldr x17, [x16, #lo12] / br x17 — the standard PLT
    // shape, minus the lazy-binding stub: every slot is bound eagerly by
    // GLOB_DAT, so there is nothing to resolve on first call.
    for (NSUInteger i = 0; i < imports.count; i++)
        {
        uint64_t here = thunkAddr + i * THUNK_SZ;
        uint64_t slot = gotOff + i * 8;
        int64_t pages = (int64_t)(slot >> 12) - (int64_t)(here >> 12);
        if (pages < -(1LL << 20) || pages >= (1LL << 20))
            {
            if (error)
                *error = elfErr(@"GOT slot for '%@' is out of adrp range", imports[i]);
            return nil;
            }
        uint32_t adrp = 0x90000010u // adrp x16, #0
                        | (uint32_t)((pages & 0x3) << 29) | (uint32_t)(((pages >> 2) & 0x7FFFF) << 5);
        uint32_t ldr = 0xF9400211u // ldr x17, [x16]
                       | (uint32_t)((((slot & 0xFFF) >> 3) & 0xFFF) << 10);
        put32v(text, adrp);
        put32v(text, ldr);
        put32v(text, 0xD61F0220u); // br x17
        put32v(text, 0xD503201Fu); // nop (pad to 16)
        }

    // ── 5. resolve the text/data fixups ───────────────────────────────────
    uint8_t *tp = text.mutableBytes, *dp = data.mutableBytes;
    for (XAArm64Fixup* f in fixups)
        {
        NSNumber* off = symbols[f.symbol];
        BOOL isGot = (f.kind == XAArm64FixupGotPage21 || f.kind == XAArm64FixupGotPageOff12);
        uint64_t target;
        if (off)
            target = ([dataSymbols containsObject:f.symbol] ? dataAddr : textAddr) + off.unsignedLongLongValue;
        else if (isGot)
            target = gotOff + importIdx[f.symbol].unsignedIntegerValue * 8;
        else
            target = thunkAddr + importIdx[f.symbol].unsignedIntegerValue * THUNK_SZ;
        target += (uint64_t)f.addend;

        if (f.kind == XAArm64FixupPointer64)
            {
            if (f.offset + 8 > data.length)
                {
                if (error)
                    *error = elfErr(@"pointer64 fixup for '%@' past end of data", f.symbol);
                return nil;
                }
            // Written with the link-time address; the RELATIVE relocation makes
            // the loader add the load bias on top.
            for (int i = 0; i < 8; i++)
                dp[f.offset + i] = (uint8_t)(target >> (8 * i));
            continue;
            }
        if (f.offset + 4 > text.length)
            {
            if (error)
                *error = elfErr(@"fixup for '%@' past end of text", f.symbol);
            return nil;
            }
        uint64_t pc = textAddr + f.offset;
        BOOL ok = YES;
        switch (f.kind)
            {
        case XAArm64FixupBranch26:
            ok = patchBranch26(tp, f.offset, (int64_t)target - (int64_t)pc, error, f.symbol);
            break;
        case XAArm64FixupPage21:
        case XAArm64FixupGotPage21:
            ok = patchAdrp(tp, f.offset, target, pc, error, f.symbol);
            break;
        case XAArm64FixupPageOff12:
            ok = patchLo12(tp, f.offset, target, f.scale, error, f.symbol);
            break;
        case XAArm64FixupGotPageOff12:
            // A GOT slot is always an 8-byte ldr, whatever the referent's size.
            ok = patchLo12(tp, f.offset, target, 3, error, f.symbol);
            break;
        default:
            if (error)
                *error = elfErr(@"unhandled fixup kind %d for '%@'",
                                (int)f.kind, f.symbol);
            ok = NO;
            }
        if (!ok)
            return nil;
        }
    uint64_t dataFileSz = fileSizeOf(data);
    uint64_t rwFileEnd = dataAddr + dataFileSz;

    // ── 6. build the file ─────────────────────────────────────────────────
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
    put16v(out, EM_AARCH64);
    put32v(out, 1);
    put64v(out, isExec ? textAddr + symbols[entrySymbol].unsignedLongLongValue : 0);
    put64v(out, EHDR_SZ);
    // e_shoff is patched below, once the file length is known: the section
    // table goes at the very END, after everything that has an address.
    NSUInteger shoffField = out.length;
    put64v(out, 0);
    put32v(out, 0);       // e_flags
    put16v(out, EHDR_SZ); // e_ehsize
    put16v(out, PHDR_SZ); // e_phentsize
    put16v(out, (uint16_t)nphdr);
    put16v(out, SHDR_SZ); // e_shentsize
    put16v(out, 4);       // e_shnum: null/.dynamic/.dynstr/.shstrtab
    put16v(out, 3);       // e_shstrndx

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
        // Both must precede the loadable segments and both must fall inside one;
        // the first PT_LOAD starts at offset 0 and covers them. PT_PHDR is not
        // optional — the loader finds the executable's program headers through it.
        phdr(PT_PHDR, PF_R, EHDR_SZ, (uint64_t)nphdr * PHDR_SZ, 8);
        phdr(PT_INTERP, PF_R, interpOff, interpSz, 1);
        }
    phdr(PT_LOAD, PF_R, 0, roEnd, ELF_PAGE);
    phdr(PT_LOAD, PF_R | PF_X, textOff, textLen, ELF_PAGE);
    // By hand: the one segment whose file and memory sizes differ.
    put32v(out, PT_LOAD);
    put32v(out, PF_R | PF_W);
    put64v(out, rwOff);
    put64v(out, rwOff);
    put64v(out, rwOff);
    put64v(out, rwFileEnd - rwOff); // p_filesz
    put64v(out, rwEnd - rwOff);     // p_memsz
    put64v(out, ELF_PAGE);
    phdr(PT_DYNAMIC, PF_R | PF_W, dynOff, nDyn * DYN_SZ, 8);
    // Present with no PF_X: without it the loader assumes an executable stack is
    // wanted and refuses to map the image.
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
    // R_AARCH64_RELATIVE
    for (XAArm64Fixup* f in absFixups)
        {
        NSNumber* off = symbols[f.symbol];
        uint64_t target = ([dataSymbols containsObject:f.symbol] ? dataAddr : textAddr) + off.unsignedLongLongValue + (uint64_t)f.addend;
        put64v(out, dataAddr + f.offset);
        put64v(out, R_AARCH64_RELATIVE);
        put64v(out, target);
        }
    // R_AARCH64_GLOB_DAT
    for (NSUInteger i = 0; i < imports.count; i++)
        {
        uint64_t symIdx = 1 + exports.count + i;
        put64v(out, gotOff + i * 8);
        put64v(out, (symIdx << 32) | R_AARCH64_GLOB_DAT);
        put64v(out, 0);
        }

    while (out.length < textOff)
        put8v(out, 0);
    [out appendData:text];
    while (out.length < gotOff)
        put8v(out, 0);
    for (NSUInteger i = 0; i < imports.count; i++)
        put64v(out, 0); // filled by the loader

    while (out.length < dynOff)
        put8v(out, 0);
    void (^dyn)(uint64_t, uint64_t) = ^(uint64_t tag, uint64_t val) {
      put64v(out, tag);
      put64v(out, val);
    };
    for (NSNumber* n in neededOff)
        dyn(DT_NEEDED, n.unsignedIntValue);
    // DT_SONAME names a LIBRARY; an executable claiming to be one confuses the
    // loader's lookup scope.
    if (!isExec)
        dyn(DT_SONAME, sonameOff);
    dyn(DT_HASH, hashOff);
    dyn(DT_STRTAB, strOffB);
    dyn(DT_SYMTAB, symOff);
    dyn(DT_STRSZ, dynstr.length);
    dyn(DT_SYMENT, SYM_SZ);
    dyn(DT_RELA, relaOff);
    dyn(DT_RELASZ, nRela * RELA_SZ);
    dyn(DT_RELAENT, RELA_SZ);
    // Bug 124. The array sits at the tail of .data; naming it here is the whole
    // mechanism, because bionic's loader walks DT_INIT_ARRAY before it enters
    // `_start`. The pointers already carry R_AARCH64_RELATIVE relocations from
    // their Pointer64 fixups, so they are correct under a PIE's random base.
    if (miLen)
        {
        dyn(DT_INIT_ARRAY, dataAddr + (data.length - miLen));
        dyn(DT_INIT_ARRAYSZ, miLen);
        }
    dyn(DT_NULL, 0);

    while (out.length < dataAddr)
        put8v(out, 0);
    [out appendBytes:data.bytes length:dataFileSz];

    // ── the section header table ──────────────────────────────────────────
    // The kernel's exec path reads program headers only, so a PIE runs with no
    // section table at all. `dlopen` does NOT, and bionic's ElfReader is
    // specific about what it wants before it will map a library:
    //
    //   * e_shstrndx < e_shnum — 0/0 is rejected as "invalid e_shstrndx";
    //   * a section of type SHT_DYNAMIC must EXIST (".dynamic section header
    //     was not found"), even though PT_DYNAMIC already says where it is;
    //   * its sh_offset and sh_size must equal PT_DYNAMIC's p_offset/p_filesz;
    //   * its sh_link must name a real SHT_STRTAB.
    //
    // So the smallest table that loads is four entries. It is appended after
    // everything addressable and lies outside every PT_LOAD's p_filesz, so
    // adding it moves no address — the executable's layout is unchanged.
    NSMutableData* shstr = [NSMutableData data];
    put8v(shstr, 0);
    uint32_t (^shName)(const char*) = ^uint32_t(const char* n) {
      uint32_t off = (uint32_t)shstr.length;
      [shstr appendBytes:n length:strlen(n) + 1];
      return off;
    };
    uint32_t nDynamic = shName(".dynamic"), nDynstr = shName(".dynstr"),
             nShstrtab = shName(".shstrtab");
    uint64_t shstrOff = out.length;
    [out appendData:shstr];
    while (out.length % 8)
        put8v(out, 0);
    uint64_t shoff = out.length;

    enum
        {
        SHT_STRTAB = 3,
        SHT_DYNAMIC = 6,
        SHF_WRITE = 1,
        SHF_ALLOC = 2
        };
    void (^shdr)(uint32_t, uint32_t, uint64_t, uint64_t, uint64_t, uint64_t,
                 uint32_t, uint64_t, uint64_t) =
        ^(uint32_t name, uint32_t type, uint64_t flags, uint64_t addr,
          uint64_t off, uint64_t size, uint32_t link, uint64_t align, uint64_t entsize) {
          put32v(out, name);
          put32v(out, type);
          put64v(out, flags);
          put64v(out, addr);
          put64v(out, off);
          put64v(out, size);
          put32v(out, link);
          put32v(out, 0); // sh_link, sh_info
          put64v(out, align);
          put64v(out, entsize);
        };
    shdr(0, 0, 0, 0, 0, 0, 0, 0, 0); // [0] the mandatory null entry
    // [1] .dynamic — sh_link names [2], where its strings live.
    shdr(nDynamic, SHT_DYNAMIC, SHF_WRITE | SHF_ALLOC, dynOff, dynOff,
         nDyn * DYN_SZ, 2, 8, DYN_SZ);
    shdr(nDynstr, SHT_STRTAB, SHF_ALLOC, strOffB, strOffB, dynstr.length, 0, 1, 0);
    shdr(nShstrtab, SHT_STRTAB, 0, 0, shstrOff, shstr.length, 0, 1, 0);

    uint8_t* ob = out.mutableBytes;
    for (int i = 0; i < 8; i++)
        ob[shoffField + i] = (uint8_t)(shoff >> (8 * i));
    return out;
    }

@end
