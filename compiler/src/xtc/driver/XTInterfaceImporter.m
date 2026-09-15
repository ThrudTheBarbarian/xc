#import "XTInterfaceImporter.h"
#import "XTASTNode.h"
#import "XTDeclNodes.h"
#import "XTType.h"
#import "XTPointerType.h"
#import "XTTypeTable.h"
#import "XTFunctionType.h"
#import "XTStructType.h"
#import "XTArrayType.h"
#import "XTEnumType.h"
#import "XTSourceLocation.h"

@implementation XTInterfaceImporter

#pragma mark - ELF section extraction

// Pull the bytes of a named section out of an ELF object (32- or 64-bit, the only
// two the toolchain emits). Minimal parse: header → section table → .shstrtab →
// match by name. Returns nil if absent or malformed. Little-endian (arm/x86).
+ (nullable NSData*)section:(NSString*)want fromELF:(NSData*)d
    {
    const uint8_t* b = d.bytes;
    NSUInteger n = d.length;
    if (n < 64 || b[0] != 0x7f || b[1] != 'E' || b[2] != 'L' || b[3] != 'F')
        return nil;
    BOOL is64 = (b[4] == 2);
    uint16_t (^u16)(NSUInteger) = ^uint16_t(NSUInteger o) {
      return o + 2 <= n ? (uint16_t)(b[o] | (b[o + 1] << 8)) : 0;
    };
    uint32_t (^u32)(NSUInteger) = ^uint32_t(NSUInteger o) {
      return o + 4 <= n ? (uint32_t)(b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | ((uint32_t)b[o + 3] << 24)) : 0;
    };
    uint64_t (^u64)(NSUInteger) = ^uint64_t(NSUInteger o) {
      return (uint64_t)u32(o) | ((uint64_t)u32(o + 4) << 32);
    };

    uint64_t shoff = is64 ? u64(0x28) : u32(0x20);
    NSUInteger eShent = is64 ? 0x3a : 0x2e;
    uint16_t shentsize = u16(eShent), shnum = u16(eShent + 2), shstrndx = u16(eShent + 4);
    if (shoff == 0 || shnum == 0 || shoff + (uint64_t)shentsize * shnum > n)
        return nil;

    // Section record field offsets (sh_name@0 always; sh_offset/sh_size differ).
    uint64_t (^shOff)(NSUInteger) = ^uint64_t(NSUInteger rec) {
      return is64 ? u64(rec + 0x18) : u32(rec + 0x10);
    };
    uint64_t (^shSize)(NSUInteger) = ^uint64_t(NSUInteger rec) {
      return is64 ? u64(rec + 0x20) : u32(rec + 0x14);
    };

    if (shstrndx >= shnum)
        return nil;
    NSUInteger strRec = (NSUInteger)(shoff + (uint64_t)shstrndx * shentsize);
    uint64_t strOff = shOff(strRec), strSize = shSize(strRec);
    if (strOff + strSize > n)
        return nil;

    for (uint16_t i = 0; i < shnum; i++)
        {
        NSUInteger rec = (NSUInteger)(shoff + (uint64_t)i * shentsize);
        uint32_t nameIdx = u32(rec);
        if (strOff + nameIdx >= n)
            continue;
        const char* nm = (const char*)(b + strOff + nameIdx);
        if (strncmp(nm, want.UTF8String, want.length + 1) != 0)
            continue;
        uint64_t off = shOff(rec), size = shSize(rec);
        if (off + size > n)
            return nil;
        return [d subdataWithRange:NSMakeRange((NSUInteger)off, (NSUInteger)size)];
        }
    return nil;
    }

#pragma mark - Mach-O section extraction

// Pull the bytes of a `SEGMENT,SECTION` out of a 64-bit Mach-O (macOS .dylib).
// The section name is capped at 16 chars, so a `.dylib` carries the interface in
// `__XTC,__iface` (vs the ELF `.xtc.iface`). Minimal parse mirroring the DWARF
// reader's segment/section walk. Little-endian only (arm64/x86-64 hosts).
+ (nullable NSData*)section:(const char*)wantSect
                    segment:(const char*)wantSeg
                  fromMachO:(NSData*)d
    {
    const uint8_t* b = d.bytes;
    NSUInteger n = d.length;
    if (n < 32)
        return nil;
    uint32_t magic = (uint32_t)(b[0] | (b[1] << 8) | (b[2] << 16) | ((uint32_t)b[3] << 24));
    if (magic != 0xFEEDFACFU)
        return nil; // MH_MAGIC_64 only
    uint32_t (^u32)(NSUInteger) = ^uint32_t(NSUInteger o) {
      return o + 4 <= n ? (uint32_t)(b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | ((uint32_t)b[o + 3] << 24)) : 0;
    };
    uint64_t (^u64)(NSUInteger) = ^uint64_t(NSUInteger o) {
      return (uint64_t)u32(o) | ((uint64_t)u32(o + 4) << 32);
    };

    uint32_t ncmds = u32(16);
    uint64_t lcOff = 32; // load commands follow the 32-byte header
    for (uint32_t i = 0; i < ncmds && lcOff + 8 <= n; i++)
        {
        uint32_t cmd = u32((NSUInteger)lcOff), cmdsize = u32((NSUInteger)lcOff + 4);
        if (cmdsize < 8 || lcOff + cmdsize > n)
            break;
        // LC_SEGMENT_64
        if (cmd == 0x19)
            {
            // nsects sits after segname(16) + 4×u64 + 2×u32 from the cmd body.
            uint32_t nsects = u32((NSUInteger)(lcOff + 8 + 16 + 4 * 8 + 2 * 4));
            uint64_t secBase = lcOff + 72; // section_64 array follows the 72-byte segment cmd
            for (uint32_t s = 0; s < nsects; s++)
                {
                uint64_t rec = secBase + (uint64_t)s * 80; // section_64 = 80 bytes
                if (rec + 80 > n)
                    break;
                char sect[17] = {0}, ssg[17] = {0};
                memcpy(sect, b + rec, 16);
                memcpy(ssg, b + rec + 16, 16);
                if (strncmp(sect, wantSect, 16) != 0 || strncmp(ssg, wantSeg, 16) != 0)
                    continue;
                uint64_t size = u64((NSUInteger)(rec + 40));
                uint32_t off = u32((NSUInteger)(rec + 48));
                if ((uint64_t)off + size > n)
                    return nil;
                return [d subdataWithRange:NSMakeRange((NSUInteger)off, (NSUInteger)size)];
                }
            }
        lcOff += cmdsize;
        }
    return nil;
    }

#pragma mark - PE/COFF section extraction

// Pull a named section's bytes out of a 64-bit PE (win64 .dll). DOS header 'MZ'
// → e_lfanew@0x3C → 'PE\0\0' → COFF header (nSections, optHdrSize) → optional
// header → section table (40-byte records: name[8], vsize, vaddr, rawSize@16,
// rawPtr@20). COFF section names cap at 8 chars, so `wantSect` must be ≤8.
+ (nullable NSData*)section:(const char*)wantSect fromPE:(NSData*)d
    {
    const uint8_t* b = d.bytes;
    NSUInteger n = d.length;
    if (n < 0x40 || b[0] != 'M' || b[1] != 'Z')
        return nil;
    uint32_t (^u32)(NSUInteger) = ^uint32_t(NSUInteger o) {
      return o + 4 <= n ? (uint32_t)(b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | ((uint32_t)b[o + 3] << 24)) : 0;
    };
    uint16_t (^u16)(NSUInteger) = ^uint16_t(NSUInteger o) {
      return o + 2 <= n ? (uint16_t)(b[o] | (b[o + 1] << 8)) : 0;
    };
    uint32_t peOff = u32(0x3C);
    if (peOff + 24 > n || u32(peOff) != 0x00004550U)
        return nil; // 'PE\0\0'
    uint16_t nSections = u16(peOff + 6);
    uint16_t optSize = u16(peOff + 20);
    NSUInteger secTab = (NSUInteger)peOff + 24 + optSize; // section table follows opt header
    for (uint16_t i = 0; i < nSections; i++)
        {
        NSUInteger rec = secTab + (NSUInteger)i * 40;
        if (rec + 40 > n)
            break;
        char nm[9] = {0};
        memcpy(nm, b + rec, 8);
        if (strncmp(nm, wantSect, 8) != 0)
            continue;
        uint32_t rawSize = u32(rec + 16), rawPtr = u32(rec + 20);
        if ((uint64_t)rawPtr + rawSize > n)
            return nil;
        return [d subdataWithRange:NSMakeRange(rawPtr, rawSize)];
        }
    return nil;
    }

// Pull the `xtc.iface` CUSTOM section out of a .wasm library (W2). Custom
// sections are id 0: [id, size LEB, nameLen LEB, name, payload…]; the
// payload after the name is the JSON.
+ (nullable NSData*)ifaceFromWasm:(NSData*)d
    {
    const uint8_t* b = d.bytes;
    NSUInteger n = d.length;
    if (n < 8 || b[0] != 0x00 || b[1] != 'a' || b[2] != 's' || b[3] != 'm')
        return nil;
    NSUInteger off = 8;
    while (off < n)
        {
        uint8_t id = b[off++];
        uint64_t size = 0;
        int shift = 0;
        // LEB128 section size
        while (off < n)
            {
            uint8_t byte = b[off++];
            size |= (uint64_t)(byte & 0x7F) << shift;
            shift += 7;
            if (!(byte & 0x80))
                break;
            }
        if (off + size > n)
            return nil;
        if (id == 0)
            {
            NSUInteger p = off;
            uint64_t nameLen = 0;
            shift = 0;
            while (p < off + size)
                {
                uint8_t byte = b[p++];
                nameLen |= (uint64_t)(byte & 0x7F) << shift;
                shift += 7;
                if (!(byte & 0x80))
                    break;
                }
            if (p + nameLen <= off + size && nameLen == 9 && memcmp(b + p, "xtc.iface", 9) == 0)
                {
                NSUInteger body = p + (NSUInteger)nameLen;
                return [d subdataWithRange:NSMakeRange(body, off + (NSUInteger)size - body)];
                }
            }
        off += (NSUInteger)size;
        }
    return nil;
    }

+ (nullable NSString*)interfaceJSONFromLibrary:(NSString*)path
    {

    // A BARE `.xtc.iface` IS the JSON — there is no container to dig it out of.
    // `xcc -c` writes one beside its object, and it plays exactly the role the
    // embedded section plays for a built library.
    if ([path.lastPathComponent hasSuffix:@".xtc.iface"])
        return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    NSData* d = [NSData dataWithContentsOfFile:path];
    if (!d)
        return nil;
    // ELF (.so on arm9 / x86-64 Linux) carries `.xtc.iface`; Mach-O (.dylib on
    // macOS arm64) carries `__XTC,__iface`; PE (.dll on win64) carries `xtciface`
    // (COFF section names cap at 8 chars); a .wasm library (W2) carries the
    // `xtc.iface` custom section.
    NSData* sec = [self section:@".xtc.iface" fromELF:d];
    if (!sec)
        sec = [self section:"__iface" segment:"__XTC" fromMachO:d];
    if (!sec)
        sec = [self section:"xtciface" fromPE:d];
    if (!sec)
        sec = [self ifaceFromWasm:d];
    if (!sec)
        return nil;
    // The section is the JSON text plus the trailing NUL we padded it with.
    NSUInteger len = sec.length;
    const uint8_t* sb = sec.bytes;
    while (len > 0 && sb[len - 1] == 0)
        len--;
    return [[NSString alloc] initWithBytes:sb length:len encoding:NSUTF8StringEncoding];
    }

#pragma mark - Declaration reconstruction

// Resolve a serialised type string (XTType.displayName form) back to an XTType.
// Handles scalars / class+protocol names (looked up in `tt`) and a trailing `@`
// pointer suffix. `protos` is the set of protocol names so a pointer to a protocol
// carries the protocolConstraint sema's conformance checks expect.
/****************************************************************************\
|* Parse an XTFunctionType displayName — `<rets>(<params>)`, e.g. `u16()`,
|* `void(u16,u8)`, `i32(u8,...)`. Used both by the `^` rebuild below and by a
|* plain `typedef u16 cb_t(void);` whose target type IS a function type.
\****************************************************************************/
+ (nullable XTFunctionType*)functionTypeFromString:(NSString*)sig
                                                tt:(XTTypeTable*)tt
                                            protos:(NSSet<NSString*>*)protos
    {
    NSRange lp = [sig rangeOfString:@"("];
    if (lp.location == NSNotFound || ![sig hasSuffix:@")"])
        return nil;

    NSString* retStr = [sig substringToIndex:lp.location];
    NSString* parStr = [sig substringWithRange:
                                NSMakeRange(lp.location + 1, sig.length - lp.location - 2)];

    BOOL varArgs = NO;
    NSMutableArray<XTType*>* rets = [NSMutableArray array];
    NSMutableArray<XTType*>* pars = [NSMutableArray array];
    for (NSString* r in [retStr componentsSeparatedByString:@","])
        {
        if (r.length == 0)
            continue;
        [rets addObject:[self typeFromString:r tt:tt protos:protos]];
        }
    for (NSString* pp in [parStr componentsSeparatedByString:@","])
        {
        if (pp.length == 0)
            continue;
        if ([pp isEqualToString:@"..."])
            {
            varArgs = YES;
            continue;
            }
        [pars addObject:[self typeFromString:pp tt:tt protos:protos]];
        }
    if (rets.count == 0)
        [rets addObject:[XTType voidType]];
    return [XTFunctionType functionWithReturnTypes:rets paramTypes:pars isVarArgs:varArgs];
    }

/****************************************************************************\
|* Rebuild a `^` (bound-method) type from its interned name, `$bound_<sig>`
|* where <sig> is an XTFunctionType displayName (`u16()`, `void(u16,u8)`, …).
|*
|* Without this, typeFromString: fell through to typeForName:, got nil, and
|* handed back VOID — so an imported `void setAction(act_t^ a)` looked like it
|* took a void parameter. The caller then had no signature to widen `&fn`
|* against, emitted NO trampoline, and the `^` crossed the .so boundary with a
|* ZERO code word. Calling it jumped to 0. (Reproduced on the XTOS loader as a
|* PREFETCH-ABORT at PC=0.)
|*
|* Must build exactly what XTParser and sema's boundMethodTypeForSignature:
|* intern — same name, same {recv, code} fields, same boundMethodSignature —
|* so the type the library DECLARES and the type the caller PRODUCES are the
|* same object.
\****************************************************************************/
+ (nullable XTType*)boundTypeFromString:(NSString*)s
                                     tt:(XTTypeTable*)tt
                                 protos:(NSSet<NSString*>*)protos
    {
    XTType* cached = [tt typeForName:s];
    if (cached)
        return cached;

    // `$bound_<sig>` and `$wbound_<sig>` — the weak form interns a DISTINCT type
    // object (the type is shared across every use, so the flag cannot be stamped on
    // the common one). Handling only `$bound_` meant `weak: act_t^` — a weak bound
    // method — could not cross an interface, even though `act_t^` alone and
    // `weak: T@` alone both could. It is the combination that was missing, and it is
    // the one a UI toolkit leans on hardest: it is target/action.
    BOOL weakBound = [s hasPrefix:@"$wbound_"];
    NSString* sig = [s substringFromIndex:(weakBound ? [@"$wbound_" length]
                                                     : [@"$bound_" length])];
    XTFunctionType* fn = [self functionTypeFromString:sig tt:tt protos:protos];
    if (!fn)
        return nil;

    XTStructField* recv = [[XTStructField alloc]
        initWithName:@"recv"
                type:[XTPointerType pointerToType:[XTType u8Type]]];
    XTStructField* code = [[XTStructField alloc]
        initWithName:@"code"
                type:[XTPointerType pointerToType:fn]];
    XTStructType* st = [XTStructType structNamed:s fields:@[ recv, code ]];
    st.boundMethodSignature = fn;
    st.isWeakBound = weakBound;
    [tt registerType:st forName:s];
    return st;
    }

+ (XTType*)typeFromString:(NSString*)s
                       tt:(XTTypeTable*)tt
                   protos:(NSSet<NSString*>*)protos
    {
    if (s.length == 0)
        return [XTType voidType];
    if ([s hasPrefix:@"$bound_"] || [s hasPrefix:@"$wbound_"])
        {
        XTType* bm = [self boundTypeFromString:s tt:tt protos:protos];
        if (bm)
            return bm;
        }
    if ([s hasSuffix:@"*"] || [s hasSuffix:@"@"])
        {
        // A pointer's displayName is `<weak:><placement:><pointee>*`, so the
        // QUALIFIERS are baked into the name. Strip them back off and rebuild the
        // pointer with them, rather than looking up the whole decorated string.
        //
        // Without this, `weak:Node@` had its `@` removed and then `weak:Node` was
        // looked up as a type name — which of course does not exist. So a weak field
        // could not cross the interface at ALL. That is structural, not incidental:
        // `weak:` is what stops a view hierarchy being one enormous retain cycle
        // (the responder chain, owner/superview, target/action), and every one of
        // those edges has to cross.
        NSString* body = [s substringToIndex:s.length - 1];
        BOOL isWeak = NO;
        XTPointerPlacement placement = XTPointerPlacementHeap;
        if ([body hasPrefix:@"weak:"])
            {
            isWeak = YES;
            body = [body substringFromIndex:5];
            }
        if ([body hasPrefix:@"shadow:"])
            {
            placement = XTPointerPlacementShadow;
            body = [body substringFromIndex:7];
            }
        else if ([body hasPrefix:@"banked:"])
            {
            placement = XTPointerPlacementBanked;
            body = [body substringFromIndex:7];
            }
        else if ([body hasPrefix:@"raw:"])
            {
            placement = XTPointerPlacementRaw;
            body = [body substringFromIndex:4];
            }
        XTType* pointee = [self typeFromString:body tt:tt protos:protos];
        return [XTPointerType pointerToType:pointee placement:placement isWeak:isWeak];
        }
    if ([protos containsObject:s])
        {
        XTType* c = [[XTType alloc] initWithKind:XTTypeKindClass displayName:s];
        c.protocolConstraint = s;
        return c;
        }
    // A bare FUNCTION type — `u16()`, `void(u16,u8)`. `typedef u16 cb_t(void);` in a
    // library serialises its target as exactly this.
    if ([s hasSuffix:@")"] && [s rangeOfString:@"("].location != NSNotFound)
        {
        XTFunctionType* ft = [self functionTypeFromString:s tt:tt protos:protos];
        if (ft)
            return ft;
        }

    // An ARRAY — `u8[32]`, `Point[4]`, or the unsized `u8[]`. XTArrayType's
    // displayName is `<element>[<count>]`, so it round-trips by taking the
    // element spelling from the left of the bracket.
    //
    // Without this, a class with an array ivar could not be exported AT ALL:
    // `--emit-lib` wrote `u8[32]` into the interface and the import failed with
    // "names the type 'u8[32]', which could not be resolved". That made the
    // failure reachable from anything importing Foundation the moment
    // CharacterSet — a 256-bit bitmap held as `u8 _bits[32]` — joined it.
    if ([s hasSuffix:@"]"])
        {
        NSRange lb = [s rangeOfString:@"[" options:NSBackwardsSearch];
        if (lb.location != NSNotFound && lb.location > 0)
            {
            NSString* elemName = [s substringToIndex:lb.location];
            NSString* countStr = [s substringWithRange:
                                        NSMakeRange(lb.location + 1, s.length - lb.location - 2)];
            XTType* elem = [self typeFromString:elemName tt:tt protos:protos];
            if (elem)
                {
                NSUInteger count = countStr.length ? (NSUInteger)countStr.integerValue : 0;
                return [XTArrayType arrayOfType:elem count:count];
                }
            }
        }
    XTType* t = [tt typeForName:s];
    if (t)
        return t;

    // A type the library's interface NAMES but that we could not reconstruct. This
    // used to fall through to VOID, in silence — which is exactly how an imported
    // struct that was never serialised looked like it worked: `u16 area(XGRect r)`
    // imported as `area(void)`, and the caller happily truncated the argument.
    //
    // Collected, not printed: the driver turns these into FATAL diagnostics. An
    // "error:" on stderr that still emits a binary is the same bug wearing a
    // warning's clothes — it built `gapp.so` with OBJECT@ silently degraded to void@.
    if (!sUnresolved)
        sUnresolved = [NSMutableSet set];
    [sUnresolved addObject:s];
    // An identifier-shaped name gets a NAMED class placeholder, not void: when
    // the unit itself declares the class (the ambient prelude surface — every
    // module's interface legitimately says `String*` now, task #36), sema's
    // source/metadata merge binds it by name and lowering lays it out for
    // real. The driver still hard-errors when the unit never declares the
    // name, so nothing silently degrades; void remains only for spellings
    // that are not identifiers at all.
    BOOL identShaped = s.length > 0;
    for (NSUInteger ci = 0; ci < s.length && identShaped; ci++)
        {
        unichar c = [s characterAtIndex:ci];
        if (!isalnum(c) && c != '_' && c != '$')
            identShaped = NO;
        if (ci == 0 && isdigit(c))
            identShaped = NO;
        }
    if (identShaped)
        return [[XTType alloc] initWithKind:XTTypeKindClass displayName:s];
    return [XTType voidType];
    }

+ (XTMethodDeclNode*)methodFrom:(NSDictionary*)m
                             tt:(XTTypeTable*)tt
                         protos:(NSSet<NSString*>*)protos
                       location:(XTSourceLocation*)loc
    {
    NSMutableArray<XTType*>* rets = [NSMutableArray array];
    for (NSString* r in (m[@"returns"] ?: @[]))
        [rets addObject:[self typeFromString:r tt:tt protos:protos]];
    if (rets.count == 0)
        [rets addObject:[XTType voidType]];
    NSMutableArray<XTParamNode*>* params = [NSMutableArray array];
    for (NSDictionary* p in (m[@"params"] ?: @[]))
        {
        XTType* pt = [self typeFromString:p[@"type"] tt:tt protos:protos];
        [params addObject:[[XTParamNode alloc] initWithType:pt name:(p[@"name"] ?: @"")location:loc]];
        }
    XTMethodDeclNode* md =
        [[XTMethodDeclNode alloc] initWithName:(m[@"name"] ?: @"")
                                   returnTypes:rets
                                    parameters:params
                                      isStatic:[m[@"static"] boolValue]
                                     isVarArgs:[m[@"varargs"] boolValue]
                                          body:nil // external: lives in the .so
                                      location:loc];
    // Round-trip the protocol `optional` flag — else the conformance re-check on
    // import demands a method a class may legally omit (e.g. Object <Comparable>
    // implements the required `equals` but omits the optional `compare`).
    md.isOptional = [m[@"optional"] boolValue];
    // §4.3b: a chain-dispatched method stays marked, so a client subclass
    // trying to override it is refused rather than silently mis-slotted.
    md.isChainMethod = [m[@"chain"] boolValue];
    // The serialised `symbol` is the full export Class$method; lowering re-adds
    // the `Class$` prefix, so store only the bare (possibly overload-mangled)
    // method part here.
    NSString* sym = m[@"symbol"];
    NSRange dollar = [sym rangeOfString:@"$"];
    if (sym.length && dollar.location != NSNotFound)
        md.mangledName = [sym substringFromIndex:dollar.location + 1];
    return md;
    }

static NSMutableSet<NSString*>* sUnresolved = nil;

+ (NSArray<NSString*>*)drainUnresolvedTypeNames
    {
    NSArray* a = sUnresolved.allObjects ?: @[];
    sUnresolved = nil;
    return [a sortedArrayUsingSelector:@selector(compare:)];
    }

+ (NSArray<NSString*>*)cImportsFromJSON:(NSString*)json
    {
    NSData* jd = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* root = jd ? [NSJSONSerialization JSONObjectWithData:jd options:0 error:NULL] : nil;
    if (![root isKindOfClass:[NSDictionary class]])
        return @[];
    NSArray* a = root[@"cImports"];
    return [a isKindOfClass:[NSArray class]] ? a : @[];
    }

+ (NSDictionary*)slotsFromJSON:(NSString*)json
    {
    NSData* jd = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* root = jd ? [NSJSONSerialization JSONObjectWithData:jd options:0 error:NULL] : nil;
    if (![root isKindOfClass:[NSDictionary class]])
        return @{};
    return @{@"protocolSlots" : root[@"protocolSlots"] ?: @{},
             @"methodSlots" : root[@"methodSlots"] ?: @{},
             // The slots the library assumed for classes it does NOT export
             // — the ambient prelude ones. Absent in an interface written
             // before 091, which simply means no assumption to honour.
             @"ambientSlots" : root[@"ambientSlots"] ?: @{}};
    }

+ (NSArray<XTASTNode*>*)declarationsFromJSON:(NSString*)json
                               intoTypeTable:(XTTypeTable*)tt
    {
    NSData* jd = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* root = jd ? [NSJSONSerialization JSONObjectWithData:jd options:0 error:NULL] : nil;
    if (![root isKindOfClass:[NSDictionary class]])
        return @[];

    NSArray* jClasses = root[@"classes"] ?: @[];
    NSArray* jProtocols = root[@"protocols"] ?: @[];
    NSArray* jEnums = root[@"enums"] ?: @[];
    NSArray* jStructs = root[@"structs"] ?: @[];
    NSArray* jFunctions = root[@"functions"] ?: @[];
    NSArray* jGlobals = root[@"globals"] ?: @[];
    NSArray* jTypedefs = root[@"typedefs"] ?: @[];

    // Collect protocol names up front (typeFromString needs them).
    NSMutableSet<NSString*>* protos = [NSMutableSet set];
    for (NSDictionary* p in jProtocols)
        if (p[@"name"])
            [protos addObject:p[@"name"]];

    // Pass 1 — register class/protocol type markers so every name resolves while we
    // build the declarations (and so the importing source can name them).
    for (NSDictionary* c in jClasses)
        {
        NSString* nm = c[@"name"];
        if (nm.length && ![tt isTypeName:nm])
            [tt registerType:[[XTType alloc] initWithKind:XTTypeKindClass displayName:nm] forName:nm];
        }
    for (NSString* pn in protos)
        {
        if (![tt isTypeName:pn])
            {
            XTType* marker = [[XTType alloc] initWithKind:XTTypeKindClass displayName:pn];
            marker.protocolConstraint = pn;
            [tt registerType:marker forName:pn];
            }
        }

    // Structs, in two passes. Shells FIRST, with no fields, so a field whose type
    // is another imported struct (or a pointer back to this one) resolves while we
    // are still building them — otherwise the order of the JSON would decide whether
    // a library's types imported correctly.
    NSMutableDictionary<NSString*, XTStructType*>* shells = [NSMutableDictionary dictionary];
    for (NSDictionary* sd in jStructs)
        {
        NSString* nm = sd[@"name"];
        if (nm.length == 0)
            continue;
        XTType* existing = [tt typeForName:nm];
        if ([existing isKindOfClass:[XTStructType class]])
            continue; // source wins
        XTStructType* shell = [XTStructType structNamed:nm fields:@[]];
        [tt registerType:shell forName:nm];
        shells[nm] = shell;
        }
    for (NSDictionary* sd in jStructs)
        {
        XTStructType* shell = shells[sd[@"name"] ?: @""];
        if (!shell)
            continue;
        NSMutableArray<XTStructField*>* fs = [NSMutableArray array];
        for (NSDictionary* f in (sd[@"fields"] ?: @[]))
            {
            XTType* ft = [self typeFromString:f[@"type"] tt:tt protos:protos];
            [fs addObject:[[XTStructField alloc] initWithName:(f[@"name"] ?: @"")
                                                         type:ft]];
            }
        [shell replaceFields:fs];                 // recomputes byteOffsets at the target's widths
        shell.packed = [sd[@"packed"] boolValue]; // absent (older iface) -> NO
        }

    // The enum TYPE, not just its constants. The constants imported (as a synthesised
    // enum decl) but the type name did not, so `MColor c = M_RED;` could not be spelled
    // — the parser had never heard of MColor.
    for (NSDictionary* e in jEnums)
        {
        NSString* nm = e[@"name"];
        if (nm.length == 0 || [tt isTypeName:nm])
            continue;
        [tt registerType:[XTEnumType enumNamed:nm members:@{}] forName:nm];
        }
    // Type aliases.
    for (NSDictionary* td in jTypedefs)
        {
        NSString* nm = td[@"name"];
        if (nm.length == 0 || [tt isTypeName:nm])
            continue;
        XTType* target = [self typeFromString:td[@"target"] tt:tt protos:protos];
        if (target)
            [tt registerType:target forName:nm];
        }

    XTSourceLocation* loc = [XTSourceLocation locationWithFilename:@"<imported>" line:0 column:0];
    NSMutableArray<XTASTNode*>* decls = [NSMutableArray array];

    // Free functions and globals: body-less / initialiser-less declarations, which the
    // backend emits as external symbols for the linker to resolve against the .so.
    for (NSDictionary* f in jFunctions)
        {
        NSString* nm = f[@"name"];
        if (nm.length == 0)
            continue;
        NSMutableArray<XTParamNode*>* params = [NSMutableArray array];
        for (NSDictionary* pd in (f[@"params"] ?: @[]))
            {
            XTType* pt = [self typeFromString:pd[@"type"] tt:tt protos:protos];
            [params addObject:[[XTParamNode alloc] initWithType:pt
                                                           name:(pd[@"name"] ?: @"")
                                                           location:loc]];
            }
        NSMutableArray<XTType*>* rets = [NSMutableArray array];
        for (NSString* r in (f[@"returns"] ?: @[]))
            [rets addObject:[self typeFromString:r tt:tt protos:protos]];
        if (rets.count == 0)
            [rets addObject:[XTType voidType]];
        XTFunctionDeclNode* proto =
            [[XTFunctionDeclNode alloc] initWithName:nm
                                         returnTypes:rets
                                          parameters:params
                                           isVarArgs:[f[@"varargs"] boolValue]
                                                body:nil
                                            location:loc];
        proto.mangledName = f[@"symbol"] ?: nm;
        [decls addObject:proto];
        }
    // GLOBALS ARE DELIBERATELY NOT IMPORTED. XTVariableDeclNode has no "external"
    // form, so injecting one here would DEFINE a second copy of the variable in the
    // client — writes through it would never reach the library's, and nothing would
    // say so. A wrong import is worse than no import: leave the honest "Undefined
    // identifier". They are serialised (so the data is there the day lowering grows
    // an extern-global), just not injected.
    (void)jGlobals;

    // Pass 2 — build the declaration nodes.
    for (NSDictionary* p in jProtocols)
        {
        NSMutableArray<XTMethodDeclNode*>* methods = [NSMutableArray array];
        for (NSDictionary* m in (p[@"methods"] ?: @[]))
            [methods addObject:[self methodFrom:m tt:tt protos:protos location:loc]];
        [decls addObject:[[XTProtocolDeclNode alloc] initWithName:(p[@"name"] ?: @"") methods:methods location:loc]];
        }
    for (NSDictionary* e in jEnums)
        {
        NSMutableArray<XTEnumMemberNode*>* members = [NSMutableArray array];
        for (NSDictionary* mem in (e[@"members"] ?: @[]))
            {
            NSNumber* v = mem[@"value"];
            XTEnumMemberNode* em = [[XTEnumMemberNode alloc] initWithName:(mem[@"name"] ?: @"")
                                                            explicitValue:v
                                                                 location:loc];
            // resolvedValue too, NOT just explicitValue. The C-library import path sets
            // both; this one set only the latter, so every imported xtc enum constant
            // evaluated to 0 — and did so quietly, because 0 is a perfectly good u16.
            em.resolvedValue = v.longLongValue;
            [members addObject:em];
            }
        [decls addObject:[[XTEnumDeclNode alloc] initWithName:(e[@"name"] ?: @"") members:members location:loc]];
        }
    for (NSDictionary* c in jClasses)
        {
        NSMutableArray<XTVariableDeclNode*>* ivars = [NSMutableArray array];
        for (NSDictionary* v in (c[@"ivars"] ?: @[]))
            {
            XTType* vt = [self typeFromString:v[@"type"] tt:tt protos:protos];
            [ivars addObject:[[XTVariableDeclNode alloc] initWithName:(v[@"name"] ?: @"")
                                                                 type:vt
                                                          initialiser:nil
                                                             location:loc]];
            }
        NSMutableArray<XTMethodDeclNode*>* methods = [NSMutableArray array];
        for (NSDictionary* m in (c[@"methods"] ?: @[]))
            [methods addObject:[self methodFrom:m tt:tt protos:protos location:loc]];
        NSString* parent = c[@"parent"];
        if (parent.length == 0)
            parent = nil;
        XTClassDeclNode* cd = [[XTClassDeclNode alloc] initWithName:(c[@"name"] ?: @"")
                                                         parentName:parent
                                                      protocolNames:(c[@"protocols"] ?: @[])
                                                      ivars:ivars
                                                            methods:methods
                                                           location:loc];
        cd.isExternal = YES; // bodies live in the .so — register externs, don't emit
        [decls addObject:cd];
        }
    return decls;
    }

@end
