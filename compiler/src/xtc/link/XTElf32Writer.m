#import "XTElf32Writer.h"

// ELF32 constants, defined in-house so the writer is host-independent (the same
// reason XTElfWriter and XTMachOWriter define their own).
enum
    {
    ELF32_ET_REL = 1,
    ELF32_EM_ARM = 40,
    ELF32_EHDR_SZ = 52,
    ELF32_SHDR_SZ = 40,
    ELF32_SYM_SZ = 16,
    ELF32_REL_SZ = 8,
    SHT_PROGBITS = 1,
    SHT_SYMTAB = 2,
    SHT_STRTAB = 3,
    SHT_NOBITS = 8,
    SHT_REL = 9,
    SHF_WRITE = 1,
    SHF_ALLOC = 2,
    SHF_EXECINSTR = 4,
    SHN_COMMON = 0xFFF2,
    STB_LOCAL = 0,
    STB_GLOBAL = 1,
    STT_NOTYPE = 0,
    STT_OBJECT = 1,
    STT_FUNC = 2,
    STV_HIDDEN = 2,
    };

static void e8(NSMutableData* d, uint8_t v)
    {
    [d appendBytes:&v length:1];
    }
static void e16(NSMutableData* d, uint16_t v)
    {
    for (int i = 0; i < 2; i++)
        e8(d, (uint8_t)(v >> (8 * i)));
    }
static void e32(NSMutableData* d, uint32_t v)
    {
    for (int i = 0; i < 4; i++)
        e8(d, (uint8_t)(v >> (8 * i)));
    }
static uint32_t align4(uint32_t v)
    {
    return (v + 3u) & ~3u;
    }

// ── ET_DYN: what the loader takes ─────────────────────────────────────────
enum
    {
    ELF32_ET_DYN = 3,
    R_ARM_GLOB_DAT = 0x15,
    R_ARM_RELATIVE = 0x17,
    DT_NEEDED_T = 1,
    DT_HASH_T = 4,
    DT_STRTAB_T = 5,
    DT_SYMTAB_T = 6,
    DT_STRSZ_T = 10,
    DT_SYMENT_T = 11,
    DT_SONAME_T = 14,
    DT_REL_T = 17,
    DT_RELSZ_T = 18,
    DT_RELENT_T = 19,
    ELF32_PAGE = 0x1000,
    VENEER_SZ = 8,
    };

static uint32_t alignUp32(uint32_t v, uint32_t a)
    {
    return (v + a - 1) & ~(a - 1);
    }

// A dynamic relocation — one the LOADER performs, built while the static ones
// are applied.
@interface XTElf32DynRel : NSObject
@property(nonatomic) uint32_t addr;
@property(nonatomic) uint32_t type;
@property(nonatomic, copy) NSString* symbol;
@end
@implementation XTElf32DynRel
@end

static XAArm32Symbol* findSym(NSArray<XAArm32Symbol*>* syms, NSString* name)
    {
    for (XAArm32Symbol* s in syms)
        if ([s.name isEqualToString:name])
            return s;
    return nil;
    }

// The runtime address of a symbol, relative to the image's own base.
static uint32_t addressOf(XAArm32Symbol* s, uint32_t textBase, uint32_t dataBase,
                          uint32_t bssBase)
    {
    if (s.section == 1)
        return textBase + s.value;
    if (s.section == 2)
        return dataBase + s.value;
    if (s.section == 3)
        return bssBase + s.value;
    return 0;
    }

static uint32_t readWord(NSMutableData* sec, uint32_t at)
    {
    if ((uint64_t)at + 4 > sec.length)
        return 0;
    const uint8_t* p = (const uint8_t*)sec.bytes + at;
    return p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    }

// `keepTop` preserves the condition and opcode bits a branch's displacement
// shares its word with.
static void patchWord(NSMutableData* sec, uint32_t at, uint32_t value, BOOL keepTop)
    {
    if ((uint64_t)at + 4 > sec.length)
        return;
    uint8_t* p = (uint8_t*)sec.mutableBytes + at;
    uint32_t old = p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    uint32_t w = keepTop ? ((old & 0xFF000000u) | (value & 0xFFFFFFu)) : value;
    p[0] = (uint8_t)w;
    p[1] = (uint8_t)(w >> 8);
    p[2] = (uint8_t)(w >> 16);
    p[3] = (uint8_t)(w >> 24);
    }

@implementation XTElf32Writer

+ (NSData*)objectFromText:(NSData*)text
                     data:(NSData*)data
                  symbols:(NSArray<XAArm32Symbol*>*)symbols
              relocations:(NSArray<XAArm32Reloc*>*)relocations
    {
    text = text ?: [NSData data];
    data = data ?: [NSData data];

    // An UNDEFINED symbol is global by definition: it is a reference the linker
    // has to satisfy from another object, and a local one it would simply refuse
    // to look for. (That is what a `bl memcpy` produces — the assembler saw the
    // name and nothing else.)
    for (XAArm32Symbol* s in symbols)
        if (s.section == 0)
            s.isGlobal = YES;

    // The ELF symbol table requires locals first, and `sh_info` on .symtab is
    // the index of the first global.
    NSMutableArray<XAArm32Symbol*>* ordered = [NSMutableArray array];
    for (XAArm32Symbol* s in symbols)
        if (!s.isGlobal)
            [ordered addObject:s];
    uint32_t firstGlobal = (uint32_t)ordered.count + 1; // +1 for the null entry
    for (XAArm32Symbol* s in symbols)
        if (s.isGlobal)
            [ordered addObject:s];

    NSMutableArray<XAArm32Reloc*>* textRel = [NSMutableArray array];
    NSMutableArray<XAArm32Reloc*>* dataRel = [NSMutableArray array];
    for (XAArm32Reloc* r in relocations)
        [(r.section == 1 ? textRel : dataRel) addObject:r];

    // ── The string table. Names are stored once, NUL-separated, and referred
    // to by byte offset; index 0 is the empty string a nameless entry points at.
    NSMutableData* strtab = [NSMutableData data];
    e8(strtab, 0);
    NSMutableDictionary<NSString*, NSNumber*>* strOff = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* symIndex = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < ordered.count; i++)
        {
        NSString* n = ordered[i].name;
        if (n.length && !strOff[n])
            {
            strOff[n] = @(strtab.length);
            [strtab appendData:[n dataUsingEncoding:NSUTF8StringEncoding]];
            e8(strtab, 0);
            }
        symIndex[n] = @(i + 1);
        }

    // Section names live in their own table, which is what `e_shstrndx` points
    // at. A relocation section exists only if it has entries, so the indices
    // below are computed rather than fixed.
    NSMutableArray<NSString*>* shNames =
        [@[ @"", @".text", @".data", @".bss" ] mutableCopy];
    if (textRel.count)
        [shNames addObject:@".rel.text"];
    if (dataRel.count)
        [shNames addObject:@".rel.data"];
    [shNames addObjectsFromArray:@[ @".symtab", @".strtab", @".shstrtab" ]];

    NSMutableData* shstr = [NSMutableData data];
    e8(shstr, 0);
    NSMutableDictionary<NSString*, NSNumber*>* shstrOff = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < shNames.count; i++)
        {
        NSString* n = shNames[i];
        shstrOff[n] = @(shstr.length);
        [shstr appendData:[n dataUsingEncoding:NSUTF8StringEncoding]];
        e8(shstr, 0);
        }

    // ── Offsets. The header is 52 bytes; everything else follows in the order
    // it is written, each aligned to four.
    uint32_t off = ELF32_EHDR_SZ;
    uint32_t textOff = off;
    off = align4(off + (uint32_t)text.length);
    uint32_t dataOff = off;
    off = align4(off + (uint32_t)data.length);
    uint32_t textRelOff = off;
    off = align4(off + (uint32_t)textRel.count * ELF32_REL_SZ);
    uint32_t dataRelOff = off;
    off = align4(off + (uint32_t)dataRel.count * ELF32_REL_SZ);
    uint32_t symOff = off;
    off = align4(off + ((uint32_t)ordered.count + 1) * ELF32_SYM_SZ);
    uint32_t strTabOff = off;
    off = align4(off + (uint32_t)strtab.length);
    uint32_t shstrTabOff = off;
    off = align4(off + (uint32_t)shstr.length);
    uint32_t shOff = off;

    // Section indices, in the order the headers are written.
    uint32_t idx = 1;
    uint32_t textIdx = idx++, dataIdx = idx++, bssIdx = idx++;
    uint32_t textRelIdx = 0, dataRelIdx = 0;
    if (textRel.count)
        textRelIdx = idx++;
    if (dataRel.count)
        dataRelIdx = idx++;
    uint32_t symIdx = idx++, strIdx = idx++, shstrIdx = idx++;
    uint32_t shCount = idx;
    (void)bssIdx;
    (void)textRelIdx;
    (void)dataRelIdx;

    NSMutableData* out = [NSMutableData data];
    // ── ELF header ────────────────────────────────────────────────────────
    e8(out, 0x7F);
    e8(out, 'E');
    e8(out, 'L');
    e8(out, 'F');
    e8(out, 1); // EI_CLASS  = ELFCLASS32
    e8(out, 1); // EI_DATA   = little-endian
    e8(out, 1); // EI_VERSION
    e8(out, 0); // EI_OSABI  = System V
    for (int i = 0; i < 8; i++)
        e8(out, 0);
    e16(out, ELF32_ET_REL);
    e16(out, ELF32_EM_ARM);
    e32(out, 1); // e_version
    e32(out, 0); // e_entry — none, this is an object
    e32(out, 0); // e_phoff
    e32(out, shOff);
    e32(out, 0x05000000); // e_flags: EABI version 5
    e16(out, ELF32_EHDR_SZ);
    e16(out, 0);
    e16(out, 0); // e_phentsize / e_phnum
    e16(out, ELF32_SHDR_SZ);
    e16(out, (uint16_t)shCount);
    e16(out, (uint16_t)shstrIdx);

    void (^pad)(uint32_t) = ^(uint32_t to) {
      while (out.length < to)
          e8(out, 0);
    };
    void (^writeRel)(NSArray<XAArm32Reloc*>*) = ^(NSArray<XAArm32Reloc*>* rs) {
      for (XAArm32Reloc* r in rs)
          {
          uint32_t n = symIndex[r.symbol] ? symIndex[r.symbol].unsignedIntValue : 0;
          e32(out, r.offset);
          e32(out, (n << 8) | ((uint32_t)r.kind & 0xFFu));
          }
    };

    pad(textOff);
    [out appendData:text];
    pad(dataOff);
    [out appendData:data];
    pad(textRelOff);
    writeRel(textRel);
    pad(dataRelOff);
    writeRel(dataRel);

    pad(symOff);
    e32(out, 0);
    e32(out, 0);
    e32(out, 0);
    e32(out, 0); // the null symbol
    for (XAArm32Symbol* s in ordered)
        {
        uint32_t shndx = 0; // SHN_UNDEF
        if (s.section == 1)
            shndx = textIdx;
        else if (s.section == 2)
            shndx = dataIdx;
        else if (s.section == 3)
            shndx = SHN_COMMON;
        uint32_t bind = s.isGlobal ? STB_GLOBAL : STB_LOCAL;
        uint32_t type = s.isFunction ? STT_FUNC : STT_NOTYPE;
        if (s.section == 3)
            {
            // COMMON: the value is the ALIGNMENT and the size the storage, which
            // is the one place those two fields swap meaning.
            bind = STB_GLOBAL;
            type = STT_OBJECT;
            }
        e32(out, s.name.length ? strOff[s.name].unsignedIntValue : 0);
        e32(out, s.value);
        e32(out, s.size);
        e8(out, (uint8_t)((bind << 4) | type));
        e8(out, (uint8_t)(s.hidden ? STV_HIDDEN : 0));
        e16(out, (uint16_t)shndx);
        }

    pad(strTabOff);
    [out appendData:strtab];
    pad(shstrTabOff);
    [out appendData:shstr];
    pad(shOff);

    // ── Section headers ───────────────────────────────────────────────────
    // name, type, flags, addr, offset, size, link, info, addralign, entsize —
    // entsize follows from the type (a symbol is 16 bytes, a REL relocation 8).
    void (^shdr)(NSString*, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t) =
        ^(NSString* name, uint32_t kind, uint32_t flags, uint32_t offset,
          uint32_t size, uint32_t link, uint32_t info, uint32_t addralign) {
          e32(out, name.length ? shstrOff[name].unsignedIntValue : 0);
          e32(out, kind);
          e32(out, flags);
          e32(out, 0 /*sh_addr*/);
          e32(out, offset);
          e32(out, size);
          e32(out, link);
          e32(out, info);
          e32(out, addralign);
          e32(out, kind == SHT_SYMTAB ? ELF32_SYM_SZ
                                      : (kind == SHT_REL ? ELF32_REL_SZ : 0));
        };
    shdr(@"", 0, 0, 0, 0, 0, 0, 0);
    shdr(@".text", SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR, textOff,
         (uint32_t)text.length, 0, 0, 4);
    shdr(@".data", SHT_PROGBITS, SHF_ALLOC | SHF_WRITE, dataOff,
         (uint32_t)data.length, 0, 0, 4);
    shdr(@".bss", SHT_NOBITS, SHF_ALLOC | SHF_WRITE,
         dataOff + (uint32_t)data.length, 0, 0, 0, 4);
    if (textRel.count)
        shdr(@".rel.text", SHT_REL, 0, textRelOff,
             (uint32_t)textRel.count * ELF32_REL_SZ, symIdx, textIdx, 4);
    if (dataRel.count)
        shdr(@".rel.data", SHT_REL, 0, dataRelOff,
             (uint32_t)dataRel.count * ELF32_REL_SZ, symIdx, dataIdx, 4);
    shdr(@".symtab", SHT_SYMTAB, 0, symOff,
         ((uint32_t)ordered.count + 1) * ELF32_SYM_SZ, strIdx, firstGlobal, 4);
    shdr(@".strtab", SHT_STRTAB, 0, strTabOff, (uint32_t)strtab.length, 0, 0, 1);
    shdr(@".shstrtab", SHT_STRTAB, 0, shstrTabOff, (uint32_t)shstr.length, 0, 0, 1);
    return out;
    }

// Resolve what can be resolved and record what cannot. A call to a symbol this
// image defines is bound here — the displacement is known once the layout is.
// An absolute word gets the address written in AND an R_ARM_RELATIVE, because
// the loader will add the bias it chose.
+ (BOOL)applyRelocs:(NSArray<XAArm32Reloc*>*)relocs
            symbols:(NSArray<XAArm32Symbol*>*)syms
               text:(NSMutableData*)textOut
               data:(NSMutableData*)dataOut
           textBase:(uint32_t)textBase
           dataBase:(uint32_t)dataBase
            bssBase:(uint32_t)bssBase
            imports:(NSArray<NSString*>*)imports
         veneerBase:(uint32_t)veneerBase
               into:(NSMutableArray<XTElf32DynRel*>*)dynRel
              error:(NSError**)error
    {
    for (XAArm32Reloc* r in relocs)
        {
        XAArm32Symbol* s = findSym(syms, r.symbol);
        uint32_t target = 0;
        NSUInteger imp = [imports indexOfObject:r.symbol];
        if (!s || s.section == 0)
            {
            if (imp == NSNotFound)
                {
                if (error)
                    *error = [NSError errorWithDomain:@"XTElf32Writer"
                                                 code:1
                                             userInfo:@{NSLocalizedDescriptionKey :
                                                            [NSString stringWithFormat:@"undefined symbol: %@", r.symbol]}];
                return NO;
                }
            if (r.kind == XAArm32RelocCall)
                {
                target = veneerBase + (uint32_t)imp * VENEER_SZ;
                }
            else
                {
                // A DATA reference to an import is left to the loader, against
                // the symbol itself.
                NSMutableData* sec = (r.section == 1) ? textOut : dataOut;
                uint32_t base = (r.section == 1) ? textBase : dataBase;
                patchWord(sec, r.offset, 0, NO);
                XTElf32DynRel* d = [XTElf32DynRel new];
                d.addr = base + r.offset;
                d.type = R_ARM_GLOB_DAT;
                d.symbol = r.symbol;
                [dynRel addObject:d];
                continue;
                }
            }
        else
            {
            target = addressOf(s, textBase, dataBase, bssBase);
            }
        NSMutableData* sec = (r.section == 1) ? textOut : dataOut;
        uint32_t base = (r.section == 1) ? textBase : dataBase;
        if (r.kind == XAArm32RelocCall)
            {
            uint32_t at = base + r.offset;
            int32_t delta = ((int32_t)target - (int32_t)at - 8) >> 2;
            patchWord(sec, r.offset, (uint32_t)delta & 0xFFFFFFu, YES);
            continue;
            }
        // REL semantics: the addend is IN the word, so the symbol's address is
        // added to what is already there rather than replacing it. `.word
        // sym+16` writes 16 and means sym+16.
        patchWord(sec, r.offset, target + readWord(sec, r.offset), NO);
        XTElf32DynRel* d = [XTElf32DynRel new];
        d.addr = base + r.offset;
        d.type = R_ARM_RELATIVE;
        d.symbol = r.symbol;
        [dynRel addObject:d];
        }
    return YES;
    }

+ (nullable NSData*)sharedObjectFromText:(NSData*)textIn
                                    data:(NSData*)dataIn
                                 symbols:(NSArray<XAArm32Symbol*>*)syms
                             relocations:(NSArray<XAArm32Reloc*>*)relocs
                                  needed:(NSArray<NSString*>*)needed
                                  soname:(NSString*)soname
                                   iface:(NSData*)iface
                                   error:(NSError**)error
    {
    NSData* text = textIn ?: [NSData data];
    NSData* data = dataIn ?: [NSData data];
        // ONE DT_NEEDED per library. The driver builds this list from two sources —
        // the `#import <Lib>` dependencies and the device sysroot scan — and libc.so
        // is in both, so an arm9 program recorded it twice. Harmless at load (a
        // second mapping of a library already mapped) but it is a contract spelled
        // in two places, and deduplicating at the point of writing means neither
        // caller has to remember.
        {
        NSMutableArray<NSString*>* uniq = [NSMutableArray array];
        for (NSString* n in (needed ?: @[]))
            if (n.length && ![uniq containsObject:n])
                [uniq addObject:n];
        needed = uniq;
        }

    uint32_t textBase = ELF32_PAGE; // leave the header page
    uint32_t codeSize = (uint32_t)text.length;

    // COMMON symbols get storage of their own, after .data. Their `value` is an
    // ALIGNMENT until here and an offset afterwards — the one place those two
    // fields swap meaning.
    uint32_t bssSize = 0;
    for (XAArm32Symbol* s in syms)
        {
        if (s.section != 3)
            continue;
        s.value = bssSize;
        bssSize = alignUp32(bssSize + s.size, 4);
        }

    // Imports: every symbol a relocation names that this image does not define.
    NSMutableArray<NSString*>* imports = [NSMutableArray array];
    for (XAArm32Reloc* r in relocs)
        {
        XAArm32Symbol* s = findSym(syms, r.symbol);
        if (s && s.section != 0)
            continue;
        if (![imports containsObject:r.symbol])
            [imports addObject:r.symbol];
        }
    uint32_t veneerBase = alignUp32(textBase + codeSize, 4);
    uint32_t textSize = (veneerBase - textBase) + (uint32_t)imports.count * VENEER_SZ;

    // The dynamic symbol table: what this image exports, then what it imports.
    // An import is an entry with no section — SHN_UNDEF is what sends the loader
    // looking for it.
    NSMutableArray<XAArm32Symbol*>* dyn = [NSMutableArray array];
    for (XAArm32Symbol* s in syms)
        if (s.isGlobal && s.section != 0)
            [dyn addObject:s];
    for (NSString* n in imports)
        {
        XAArm32Symbol* s = [XAArm32Symbol new];
        s.name = n;
        [dyn addObject:s];
        }

    NSMutableData* dynstr = [NSMutableData data];
    e8(dynstr, 0);
    NSMutableArray<NSNumber*>* neededOff = [NSMutableArray array];
    for (NSString* n in needed)
        {
        [neededOff addObject:@(dynstr.length)];
        [dynstr appendData:[n dataUsingEncoding:NSUTF8StringEncoding]];
        e8(dynstr, 0);
        }
    uint32_t sonameOff = 0;
    if (soname.length)
        {
        sonameOff = (uint32_t)dynstr.length;
        [dynstr appendData:[soname dataUsingEncoding:NSUTF8StringEncoding]];
        e8(dynstr, 0);
        }
    NSMutableArray<NSNumber*>* nameOff = [NSMutableArray array];
    for (XAArm32Symbol* s in dyn)
        {
        [nameOff addObject:@(dynstr.length)];
        [dynstr appendData:[s.name dataUsingEncoding:NSUTF8StringEncoding]];
        e8(dynstr, 0);
        }

    uint32_t symCount = (uint32_t)dyn.count + 1; // + the null entry
    uint32_t nbucket = 1;                        // one chain is enough
    uint32_t dynCount = 9 + (uint32_t)needed.count + (soname.length ? 1 : 0);

    // Where everything lands: the read-only metadata sits in the text segment
    // after the code, and the writable segment starts on the next page.
    uint32_t off = alignUp32(textBase + textSize, 4);
    uint32_t hashAddr = off;
    off += 4 * (2 + nbucket + symCount);
    uint32_t symAddr = alignUp32(off, 4);
    off = symAddr + symCount * 16;
    uint32_t strAddr = off;
    off += (uint32_t)dynstr.length;

    // The relocation COUNT has to be known before the layout that holds them,
    // and the relocations depend on the layout — so they are applied once
    // against a provisional data base purely to count, and again below against
    // the final one. Patching the image twice would be cheaper and far easier
    // to get wrong.
    uint32_t provisional = alignUp32(off + 64, ELF32_PAGE);
    NSMutableData *t0 = [text mutableCopy], *d0 = [data mutableCopy];
    NSMutableArray<XTElf32DynRel*>* count0 = [NSMutableArray array];
    if (![self applyRelocs:relocs
                   symbols:syms
                      text:t0
                      data:d0
                  textBase:textBase
                  dataBase:provisional
                   bssBase:provisional
                   imports:imports
                veneerBase:veneerBase
                      into:count0
                     error:error])
        return nil;
    uint32_t nDynRel = (uint32_t)count0.count + (uint32_t)imports.count;

    uint32_t relAddr = alignUp32(off, 4);
    off = relAddr + nDynRel * 8;
    uint32_t dynAddr = alignUp32(off, 4);
    uint32_t dynEnd = dynAddr + dynCount * 8;
    uint32_t dataBase = alignUp32(dynEnd, ELF32_PAGE);
    uint32_t bssBase = alignUp32(dataBase + (uint32_t)data.length, 4);

    NSMutableData *textOut = [text mutableCopy], *dataOut = [data mutableCopy];
    NSMutableArray<XTElf32DynRel*>* dynRel = [NSMutableArray array];
    if (![self applyRelocs:relocs
                   symbols:syms
                      text:textOut
                      data:dataOut
                  textBase:textBase
                  dataBase:dataBase
                   bssBase:bssBase
                   imports:imports
                veneerBase:veneerBase
                      into:dynRel
                     error:error])
        return nil;
    // Each veneer's word is resolved by the loader against its symbol.
    for (NSUInteger i = 0; i < imports.count; i++)
        {
        XTElf32DynRel* d = [XTElf32DynRel new];
        d.addr = veneerBase + (uint32_t)i * VENEER_SZ + 4;
        d.type = R_ARM_GLOB_DAT;
        d.symbol = imports[i];
        [dynRel addObject:d];
        }
    if (dynRel.count != nDynRel)
        {
        if (error)
            *error = [NSError errorWithDomain:@"XTElf32Writer"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey :
                                                    @"relocation count moved between the sizing and emitting passes"}];
        return nil;
        }

    // ── Emit ──────────────────────────────────────────────────────────────
    NSMutableData* out = [NSMutableData data];
    void (^pad)(uint32_t) = ^(uint32_t to) {
      while (out.length < to)
          e8(out, 0);
    };
    const uint8_t ident[16] = {0x7F, 'E', 'L', 'F', 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    [out appendBytes:ident length:16];
    e16(out, ELF32_ET_DYN);
    e16(out, ELF32_EM_ARM);
    e32(out, 1);
    e32(out, 0);          // e_entry — the loader finds `main`
    e32(out, 52);         // e_phoff
    e32(out, 0);          // e_shoff — no section headers
    e32(out, 0x05000000); // e_flags: EABI 5
    e16(out, 52);
    e16(out, 32);
    e16(out, 3); // ehsize, phentsize, phnum
    e16(out, 40);
    e16(out, 0);
    e16(out, 0);

    void (^phdr)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t) =
        ^(uint32_t kind, uint32_t vaddr, uint32_t filesz, uint32_t memsz,
          uint32_t flags, uint32_t align) {
          e32(out, kind);
          e32(out, vaddr); // p_offset — mapped 1:1
          e32(out, vaddr);
          e32(out, vaddr);
          e32(out, filesz);
          e32(out, memsz);
          e32(out, flags);
          e32(out, align);
        };
    phdr(1 /*PT_LOAD*/, textBase, dynEnd - textBase, dynEnd - textBase, 5 /*R+X*/, ELF32_PAGE);
    phdr(1 /*PT_LOAD*/, dataBase, (uint32_t)data.length,
         bssSize + (uint32_t)data.length, 6 /*R+W*/, ELF32_PAGE);
    phdr(2 /*PT_DYNAMIC*/, dynAddr, dynCount * 8, dynCount * 8, 6, 4);

    pad(textBase);
    [out appendData:textOut];
    // The veneers, two words each: `ldr pc, [pc, #-4]` reads the word that
    // follows it (pc reads as the instruction's address plus eight), and the
    // loader writes the resolved address into that word.
    pad(veneerBase);
    for (NSUInteger i = 0; i < imports.count; i++)
        {
        e32(out, 0xE51FF004u);
        e32(out, 0);
        }

    pad(hashAddr);
    e32(out, nbucket);
    e32(out, symCount); // nchain — the loader's symbol count
    e32(out, symCount > 1 ? 1 : 0);
    for (uint32_t i = 0; i < symCount; i++)
        e32(out, i + 1 < symCount ? i + 1 : 0);

    pad(symAddr);
    e32(out, 0);
    e32(out, 0);
    e32(out, 0);
    e32(out, 0); // the null entry
    for (NSUInteger i = 0; i < dyn.count; i++)
        {
        XAArm32Symbol* s = dyn[i];
        e32(out, nameOff[i].unsignedIntValue);
        e32(out, addressOf(s, textBase, dataBase, bssBase));
        e32(out, s.size);
        e8(out, (uint8_t)((STB_GLOBAL << 4) | (s.isFunction ? STT_FUNC : STT_OBJECT)));
        e8(out, (uint8_t)(s.hidden ? STV_HIDDEN : 0));
        e16(out, (uint16_t)(s.section == 0 ? 0 : 1));
        }

    pad(strAddr);
    [out appendData:dynstr];

    pad(relAddr);
    for (XTElf32DynRel* r in dynRel)
        {
        e32(out, r.addr);
        if (r.type == R_ARM_RELATIVE)
            {
            e32(out, R_ARM_RELATIVE);
            continue;
            }
        uint32_t si = 0;
        for (NSUInteger k = 0; k < dyn.count; k++)
            if ([dyn[k].name isEqualToString:r.symbol])
                {
                si = (uint32_t)k + 1;
                break;
                }
        e32(out, (si << 8) | r.type);
        }

    pad(dynAddr);
    void (^dynEntry)(uint32_t, uint32_t) = ^(uint32_t tag, uint32_t val) {
      e32(out, tag);
      e32(out, val);
    };
    // DT_NEEDED first: the loader has to have the library mapped before it can
    // resolve a name into it.
    for (NSUInteger i = 0; i < needed.count; i++)
        dynEntry(DT_NEEDED_T, neededOff[i].unsignedIntValue);
    if (soname.length)
        dynEntry(DT_SONAME_T, sonameOff);
    dynEntry(DT_HASH_T, hashAddr);
    dynEntry(DT_SYMTAB_T, symAddr);
    dynEntry(DT_STRTAB_T, strAddr);
    dynEntry(DT_STRSZ_T, (uint32_t)dynstr.length);
    dynEntry(DT_SYMENT_T, 16);
    dynEntry(DT_REL_T, relAddr);
    dynEntry(DT_RELSZ_T, nDynRel * 8);
    dynEntry(DT_RELENT_T, 8);
    dynEntry(0 /*DT_NULL*/, 0);

    pad(dataBase);
    [out appendData:dataOut];

    // ── Section header table ──────────────────────────────────────────────
    // The LOADER never reads this — it works from the program headers alone,
    // which is why the image ran fine without one. But every ordinary tool
    // reads sections: `#import <lib>` finds `.xtc.iface` through them (without
    // it the importer says "bad section header table" and an in-house library
    // cannot be imported at all), and so do readelf -S and nm -D, which report
    // NOTHING for a section-less image and cost real debugging time twice
    // before this existed.
    //
    // Everything here is appended AFTER the mapped segments and is not in any
    // PT_LOAD, so adding it cannot perturb a layout the loader already agreed
    // with. File offsets equal virtual addresses for the mapped sections,
    // because the segments above are mapped 1:1.
    uint32_t ifaceOff = 0, ifaceLen = (uint32_t)iface.length;
    if (ifaceLen)
        {
        while (out.length & 3)
            e8(out, 0);
        ifaceOff = (uint32_t)out.length;
        [out appendData:iface];
        e8(out, 0); // NUL-terminate, as the .incbin form did
        ifaceLen = (uint32_t)out.length - ifaceOff;
        }

    NSArray<NSString*>* secNames = @[ @"", @".text", @".hash", @".dynsym", @".dynstr",
                                      @".rel.dyn", @".dynamic", @".data", @".bss",
                                      @".xtc.iface", @".shstrtab" ];
    NSMutableData* shstr = [NSMutableData data];
    NSMutableArray<NSNumber*>* secNameOff = [NSMutableArray array];
    for (NSString* n in secNames)
        {
        [secNameOff addObject:@(shstr.length)];
        [shstr appendData:[n dataUsingEncoding:NSUTF8StringEncoding]];
        e8(shstr, 0);
        }
    while (out.length & 3)
        e8(out, 0);
    uint32_t shstrOff = (uint32_t)out.length;
    [out appendData:shstr];

    while (out.length & 3)
        e8(out, 0);
    uint32_t shoff = (uint32_t)out.length;
    // name, type, flags, addr, offset, size, link, info, align, entsize
    void (^shdr)(NSUInteger, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                 uint32_t, uint32_t, uint32_t, uint32_t) =
        ^(NSUInteger ni, uint32_t type, uint32_t flags, uint32_t addr, uint32_t offset,
          uint32_t size, uint32_t link, uint32_t info, uint32_t align, uint32_t entsize) {
          e32(out, secNameOff[ni].unsignedIntValue);
          e32(out, type);
          e32(out, flags);
          e32(out, addr);
          e32(out, offset);
          e32(out, size);
          e32(out, link);
          e32(out, info);
          e32(out, align);
          e32(out, entsize);
        };
    enum
        {
        SHT_PROGBITS_T = 1,
        SHT_SYMTAB_T = 2,
        SHT_STRTAB_T = 3,
        SHT_HASH_T = 5,
        SHT_DYNAMIC_T = 6,
        SHT_NOBITS_T = 8,
        SHT_REL_T = 9,
        SHT_DYNSYM_T = 11,
        SHF_WRITE_T = 1,
        SHF_ALLOC_T = 2,
        SHF_EXEC_T = 4
        };
    shdr(0, 0, 0, 0, 0, 0, 0, 0, 0, 0); // null
    shdr(1, SHT_PROGBITS_T, SHF_ALLOC_T | SHF_EXEC_T, textBase, textBase, textSize, 0, 0, 4, 0);
    shdr(2, SHT_HASH_T, SHF_ALLOC_T, hashAddr, hashAddr,
         4 * (2 + nbucket + symCount), 3 /*link=.dynsym*/, 0, 4, 4);
    shdr(3, SHT_DYNSYM_T, SHF_ALLOC_T, symAddr, symAddr, symCount * 16,
         4 /*link=.dynstr*/, 1 /*first global*/, 4, 16);
    shdr(4, SHT_STRTAB_T, SHF_ALLOC_T, strAddr, strAddr, (uint32_t)dynstr.length, 0, 0, 1, 0);
    shdr(5, SHT_REL_T, SHF_ALLOC_T, relAddr, relAddr, nDynRel * 8, 3, 0, 4, 8);
    shdr(6, SHT_DYNAMIC_T, SHF_ALLOC_T | SHF_WRITE_T, dynAddr, dynAddr, dynCount * 8,
         4 /*link=.dynstr*/, 0, 4, 8);
    shdr(7, SHT_PROGBITS_T, SHF_ALLOC_T | SHF_WRITE_T, dataBase, dataBase,
         (uint32_t)data.length, 0, 0, 4, 0);
    shdr(8, SHT_NOBITS_T, SHF_ALLOC_T | SHF_WRITE_T, bssBase, bssBase, bssSize, 0, 0, 4, 0);
    // NOT SHF_ALLOC: the interface is build-time metadata, read from the FILE
    // by the compiler and never mapped at run time.
    shdr(9, SHT_PROGBITS_T, 0, 0, ifaceOff, ifaceLen, 0, 0, 4, 0);
    shdr(10, SHT_STRTAB_T, 0, 0, shstrOff, (uint32_t)shstr.length, 0, 0, 4, 0);

    // Patch the header fields left at zero: e_shoff (32), e_shentsize (46),
    // e_shnum (48), e_shstrndx (50).
    uint8_t* hb = (uint8_t*)out.mutableBytes;
    for (int i = 0; i < 4; i++)
        hb[32 + i] = (uint8_t)(shoff >> (8 * i));
    hb[46] = 40;
    hb[47] = 0; // e_shentsize
    hb[48] = (uint8_t)secNames.count;
    hb[49] = 0; // e_shnum
    hb[50] = (uint8_t)(secNames.count - 1);
    hb[51] = 0; // e_shstrndx
    return out;
    }

@end

// ── ET_REL: the read direction ────────────────────────────────────────────
// The mirror of objectFromText:, and short because it only ever reads objects
// THIS compiler wrote. Measured across the fixture corpus (classes, ARC, int64,
// threads, vectorised code), our arm9 objects carry exactly TWO relocation
// types — R_ARM_ABS32 and R_ARM_CALL, the two XAArm32RelocKind already names.
// A third is an error rather than something silently skipped.
//
// Returns the ASSEMBLER's model (XAArm32Symbol / XAArm32Reloc), because the
// caller merges an object into an assembled unit and hands the whole thing to
// sharedObjectFromText: — reusing that one writer call is what keeps a
// linked-from-objects image the same shape as a linked-from-source one.
@implementation XTElf32Writer (Read)

+ (nullable NSDictionary*)objectFromData:(NSData*)d
    {
    enum
        {
        R_ABS32 = 0x02,
        R_CALL = 0x1C,
        SHT_REL_T = 9,
        SYM_SZ = 16,
        SHN_COMMON_T = 0xFFF2
        };
    if (d.length < 52)
        return nil;
    const uint8_t* b = d.bytes;
    if (memcmp(b, "\177ELF", 4) != 0 || b[4] != 1 || b[5] != 1)
        return nil; // ELF32 LE
    uint16_t (^r16)(uint32_t) = ^uint16_t(uint32_t o) {
      return (uint16_t)(b[o] | (b[o + 1] << 8));
    };
    uint32_t (^r32)(uint32_t) = ^uint32_t(uint32_t o) {
      return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | ((uint32_t)b[o + 3] << 24);
    };
    if (r16(16) != 1)
        return nil; // ET_REL only
    uint32_t shoff = r32(32);
    uint16_t shentsz = r16(46), shnum = r16(48), shstrndx = r16(50);
    if (!shnum || shoff + (uint32_t)shnum * shentsz > d.length)
        return nil;
    uint32_t (^sh)(uint16_t, uint32_t) = ^uint32_t(uint16_t i, uint32_t f) {
      return r32(shoff + (uint32_t)i * shentsz + f);
    };
    uint32_t shstrOff = sh(shstrndx, 16);

    uint16_t textIdx = 0, dataIdx = 0, symIdx = 0, strIdx = 0;
    for (uint16_t i = 1; i < shnum; i++)
        {
        uint32_t o = shstrOff + sh(i, 0);
        NSString* n = (o < d.length) ? @((const char*)(b + o)) : @"";
        if ([n isEqualToString:@".text"])
            textIdx = i;
        else if ([n isEqualToString:@".data"])
            dataIdx = i;
        else if ([n isEqualToString:@".symtab"])
            symIdx = i;
        else if ([n isEqualToString:@".strtab"])
            strIdx = i;
        }
    if (!symIdx || !strIdx)
        return nil;
    NSData* text = textIdx ? [d subdataWithRange:NSMakeRange(sh(textIdx, 16), sh(textIdx, 20))]
                           : [NSData data];
    NSData* data = dataIdx ? [d subdataWithRange:NSMakeRange(sh(dataIdx, 16), sh(dataIdx, 20))]
                           : [NSData data];

    uint32_t symOff = sh(symIdx, 16), strOff = sh(strIdx, 16);
    uint32_t nsym = sh(symIdx, 20) / SYM_SZ;
    NSMutableArray<XAArm32Symbol*>* syms = [NSMutableArray array];
    NSMutableArray<NSString*>* byIndex = [NSMutableArray array];
    for (uint32_t i = 0; i < nsym; i++)
        {
        uint32_t e = symOff + i * SYM_SZ;
        NSString* nm = @((const char*)(b + strOff + r32(e)));
        [byIndex addObject:nm];
        if (!i || !nm.length)
            continue; // the null entry
        uint16_t shndx = r16(e + 14);
        uint8_t info = b[e + 12], other = b[e + 13];
        // A COMMON symbol is NOT droppable: `__sdata_<Class>` and
        // `__sinit_<Class>` — the static-init state every class-using module
        // has — live here, and the writer gives them bss storage from
        // section 3, where `value` means ALIGNMENT rather than an offset.
        // Skipping them linked fine and faulted at run time.
        uint32_t sec;
        if (shndx == SHN_COMMON_T)
            sec = 3;
        else if (textIdx && shndx == textIdx)
            sec = 1;
        else if (dataIdx && shndx == dataIdx)
            sec = 2;
        else if (shndx == 0)
            sec = 0; // undefined: the link resolves it
        else
            continue; // .bss &c, carried by nothing here
        XAArm32Symbol* s = [XAArm32Symbol new];
        s.name = nm;
        s.section = sec;
        s.value = r32(e + 4);
        s.size = r32(e + 8);
        s.isGlobal = ((info >> 4) != 0);
        s.isFunction = ((info & 0xF) == 2);
        s.hidden = ((other & 0x3) == 2);
        [syms addObject:s];
        }

    NSMutableArray<XAArm32Reloc*>* relocs = [NSMutableArray array];
    for (uint16_t i = 1; i < shnum; i++)
        {
        if (sh(i, 4) != SHT_REL_T)
            continue;
        // sh_info is at 28 in an ELF32 section header. Reading 36 gets
        // sh_entsize (always 8 for REL), which matches no section index, so
        // EVERY relocation was silently skipped — the image linked, and every
        // call in it went unrelocated.
        uint32_t target = sh(i, 28); // sh_info: the section relocated
        uint32_t which = (textIdx && target == textIdx)   ? 1
                         : (dataIdx && target == dataIdx) ? 2
                                                          : 0;
        if (!which)
            continue;
        uint32_t ro = sh(i, 16), rsz = sh(i, 20);
        for (uint32_t o = 0; o + 8 <= rsz; o += 8)
            {
            uint32_t off = r32(ro + o), info = r32(ro + o + 4);
            uint32_t type = info & 0xFF, sidx = info >> 8;
            if (type != R_ABS32 && type != R_CALL)
                return nil;
            if (sidx >= byIndex.count)
                return nil;
            XAArm32Reloc* r = [XAArm32Reloc new];
            r.section = which;
            r.offset = off;
            r.symbol = byIndex[sidx];
            r.kind = (type == R_ABS32) ? XAArm32RelocAbs32 : XAArm32RelocCall;
            [relocs addObject:r];
            }
        }
    return @{@"text" : text, @"data" : data, @"symbols" : syms, @"relocs" : relocs};
    }

@end
