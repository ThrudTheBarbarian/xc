#import "XTDwarfReader.h"
#import "XTType.h"
#import "XTPointerType.h"
#import "XTStructType.h"
#import "XTArrayType.h"
#import "XTEnumType.h"
#import "XTFunctionType.h"

NSString* const XTDwarfErrorDomain = @"XTDwarfErrorDomain";

// ─────────────────────────────────────────────────────────────────────────
//  ELF constants (only what we touch)
// ─────────────────────────────────────────────────────────────────────────
enum
    {
    SHT_STRTAB = 3,
    SHT_DYNAMIC = 6,
    SHT_DYNSYM = 11,
    DT_NULL = 0,
    DT_SONAME = 14,
    STB_GLOBAL = 1,
    STB_WEAK = 2,
    STT_OBJECT = 1,
    STT_FUNC = 2,
    SHN_UNDEF = 0,
    };

// ─────────────────────────────────────────────────────────────────────────
//  DWARF constants
// ─────────────────────────────────────────────────────────────────────────
// tags
enum
    {
    DW_TAG_array_type = 0x01,
    DW_TAG_enumeration_type = 0x04,
    DW_TAG_formal_parameter = 0x05,
    DW_TAG_member = 0x0d,
    DW_TAG_pointer_type = 0x0f,
    DW_TAG_compile_unit = 0x11,
    DW_TAG_structure_type = 0x13,
    DW_TAG_subroutine_type = 0x15,
    DW_TAG_typedef = 0x16,
    DW_TAG_union_type = 0x17,
    DW_TAG_unspecified_parameters = 0x18,
    DW_TAG_variable = 0x34,
    DW_TAG_volatile_type = 0x35,
    DW_TAG_base_type = 0x24,
    DW_TAG_const_type = 0x26,
    DW_TAG_enumerator = 0x28,
    DW_TAG_subrange_type = 0x21,
    DW_TAG_subprogram = 0x2e,
    DW_TAG_restrict_type = 0x37,
    };
// attributes
enum
    {
    DW_AT_sibling = 0x01,
    DW_AT_name = 0x03,
    DW_AT_byte_size = 0x0b,
    DW_AT_language = 0x13,
    DW_AT_comp_dir = 0x1b,
    DW_AT_const_value = 0x1c,
    DW_AT_lower_bound = 0x22,
    DW_AT_producer = 0x25,
    DW_AT_prototyped = 0x27,
    DW_AT_count = 0x37,
    DW_AT_data_member_location = 0x38,
    DW_AT_decl_file = 0x3a,
    DW_AT_declaration = 0x3c,
    DW_AT_encoding = 0x3e,
    DW_AT_external = 0x3f,
    DW_AT_type = 0x49,
    DW_AT_upper_bound = 0x2f,
    DW_AT_low_pc = 0x11,
    DW_AT_high_pc = 0x12,
    DW_AT_linkage_name = 0x6e,
    };
// forms
enum
    {
    DW_FORM_addr = 0x01,
    DW_FORM_block2 = 0x03,
    DW_FORM_block4 = 0x04,
    DW_FORM_data2 = 0x05,
    DW_FORM_data4 = 0x06,
    DW_FORM_data8 = 0x07,
    DW_FORM_string = 0x08,
    DW_FORM_block = 0x09,
    DW_FORM_block1 = 0x0a,
    DW_FORM_data1 = 0x0b,
    DW_FORM_flag = 0x0c,
    DW_FORM_sdata = 0x0d,
    DW_FORM_strp = 0x0e,
    DW_FORM_udata = 0x0f,
    DW_FORM_ref_addr = 0x10,
    DW_FORM_ref1 = 0x11,
    DW_FORM_ref2 = 0x12,
    DW_FORM_ref4 = 0x13,
    DW_FORM_ref8 = 0x14,
    DW_FORM_ref_udata = 0x15,
    DW_FORM_indirect = 0x16,
    DW_FORM_sec_offset = 0x17,
    DW_FORM_exprloc = 0x18,
    DW_FORM_flag_present = 0x19,
    DW_FORM_strx = 0x1a,
    DW_FORM_addrx = 0x1b,
    DW_FORM_ref_sup4 = 0x1c,
    DW_FORM_strp_sup = 0x1d,
    DW_FORM_data16 = 0x1e,
    DW_FORM_line_strp = 0x1f,
    DW_FORM_ref_sig8 = 0x20,
    DW_FORM_implicit_const = 0x21,
    DW_FORM_loclistx = 0x22,
    DW_FORM_rnglistx = 0x23,
    DW_FORM_ref_sup8 = 0x24,
    DW_FORM_strx1 = 0x25,
    DW_FORM_strx2 = 0x26,
    DW_FORM_strx3 = 0x27,
    DW_FORM_strx4 = 0x28,
    DW_FORM_addrx1 = 0x29,
    DW_FORM_addrx2 = 0x2a,
    DW_FORM_addrx3 = 0x2b,
    DW_FORM_addrx4 = 0x2c,
    };
// base-type encodings (DW_ATE_*)
enum
    {
    DW_ATE_boolean = 0x02,
    DW_ATE_float = 0x04,
    DW_ATE_signed = 0x05,
    DW_ATE_signed_char = 0x06,
    DW_ATE_unsigned = 0x07,
    DW_ATE_unsigned_char = 0x08,
    };
#define DW_OP_plus_uconst 0x23

// ─────────────────────────────────────────────────────────────────────────
//  Byte cursor over a raw section
// ─────────────────────────────────────────────────────────────────────────
typedef struct
    {
    const uint8_t* base; // section start
    const uint8_t* p;    // current
    const uint8_t* end;  // one past last valid byte
    BOOL le;             // little-endian
    BOOL ok;             // cleared on any out-of-bounds read
    } Cur;

static inline BOOL curHas(Cur* c, size_t n)
    {
    if (!c->ok || (size_t)(c->end - c->p) < n)
        {
        c->ok = NO;
        return NO;
        }
    return YES;
    }
static uint8_t rdU8(Cur* c)
    {
    if (!curHas(c, 1))
        return 0;
    return *c->p++;
    }
static uint64_t rdN(Cur* c, int n)
    {
    if (!curHas(c, (size_t)n))
        return 0;
    uint64_t v = 0;
    if (c->le)
        {
        for (int i = 0; i < n; i++)
            v |= (uint64_t)c->p[i] << (8 * i);
        }
    else
        {
        for (int i = 0; i < n; i++)
            v = (v << 8) | c->p[i];
        }
    c->p += n;
    return v;
    }
static uint16_t rdU16(Cur* c)
    {
    return (uint16_t)rdN(c, 2);
    }
static uint32_t rdU32(Cur* c)
    {
    return (uint32_t)rdN(c, 4);
    }
static uint64_t rdU64(Cur* c)
    {
    return rdN(c, 8);
    }
static uint64_t rdULEB(Cur* c)
    {
    uint64_t r = 0;
    int s = 0;
    uint8_t b;
    do
        {
        if (!curHas(c, 1))
            return r;
        b = *c->p++;
        r |= (uint64_t)(b & 0x7f) << s;
        s += 7;
        } while ((b & 0x80) && s < 64);
    return r;
    }
static int64_t rdSLEB(Cur* c)
    {
    int64_t r = 0;
    int s = 0;
    uint8_t b = 0;
    do
        {
        if (!curHas(c, 1))
            return r;
        b = *c->p++;
        r |= (int64_t)(b & 0x7f) << s;
        s += 7;
        } while ((b & 0x80) && s < 64);
    if (s < 64 && (b & 0x40))
        r |= -((int64_t)1 << s);
    return r;
    }

// Safe byteWidth: a 0-width type (void/auto) would silently collapse the
// running struct offset, so floor it at 1. Such a type shouldn't appear in a
// member, but a malformed DWARF could produce one.
static NSUInteger safeByteWidth(XTType* t)
    {
    NSUInteger w = t.byteWidth;
    return w == 0 ? 1 : w;
    }

// ─────────────────────────────────────────────────────────────────────────
//  Parsed DIE (only the attributes we consume are retained)
// ─────────────────────────────────────────────────────────────────────────
@interface XTDwDIE : NSObject
    {
  @public
    uint64_t offset; // absolute .debug_info offset (the ref target)
    uint32_t tag;
    NSString* name;        // DW_AT_name
    NSString* linkageName; // DW_AT_linkage_name
    BOOL hasType;
    uint64_t typeRef; // DW_AT_type → absolute .debug_info offset
    BOOL hasByteSize;
    uint64_t byteSize;
    uint64_t encoding; // DW_AT_encoding
    BOOL hasMemberLoc;
    uint64_t memberLoc; // DW_AT_data_member_location (byte offset)
    BOOL hasConstValue;
    int64_t constValue; // DW_AT_const_value (enumerators)
    BOOL hasCount;      // array DW_AT_count or upper_bound+1
    uint64_t count;
    BOOL external;
    BOOL declaration;
    NSMutableArray<XTDwDIE*>* children;
    }
@end
@implementation XTDwDIE
- (instancetype)init
    {
    if ((self = [super init]))
        {
        children = [NSMutableArray array];
        }
    return self;
    }
@end

// One abbreviation declaration.
@interface XTDwAbbrev : NSObject
    {
  @public
    uint32_t tag;
    BOOL hasChildren;
    NSMutableArray<NSNumber*>* attrs; // flat: attr, form, implicitConst triples
    }
@end
@implementation XTDwAbbrev
- (instancetype)init
    {
    if ((self = [super init]))
        {
        attrs = [NSMutableArray array];
        }
    return self;
    }
@end

@implementation XTDwarfReader
    {
    NSData* _image;
    const uint8_t* _bytes;
    NSUInteger _len;
    BOOL _le;
    int _elfClass;        // 1 = ELFCLASS32, 2 = ELFCLASS64
    NSUInteger _ptrWidth; // target native pointer width (struct-pad math)
    NSString* _diskPath;  // on-disk path (nil for in-memory) — locates a .dSYM sidecar

    // Mach-O LC_SYMTAB (0 when not a Mach-O / no symtab) — exports come from here.
    uint64_t _machoSymOff, _machoNSyms, _machoStrOff, _machoStrSize;

    // section name → (offset, size)
    NSMutableDictionary<NSString*, NSArray<NSNumber*>*>* _sections;

    // DWARF working state
    Cur _info, _abbrev, _str, _lineStr, _strOffsets;
    NSMutableDictionary<NSNumber*, XTDwDIE*>* _dieByOffset; // ref target → DIE
    NSMutableDictionary<NSNumber*, XTType*>* _typeCache;    // DIE offset → xtc type
    NSMutableDictionary<NSString*, XTType*>* _namedTypes;   // export dictionary
    NSMutableSet<NSNumber*>* _inProgress;                   // cycle guard
    }

// ───────────────────────── public entry points ──────────────────────────

+ (nullable XTDwarfInterface*)readInterfaceFromPath:(NSString*)path
                                              error:(NSError**)error
    {
    return [self readInterfaceFromPath:path targetPointerWidth:2 error:error];
    }

+ (nullable XTDwarfInterface*)readInterfaceFromPath:(NSString*)path
                                 targetPointerWidth:(NSUInteger)ptrWidth
                                              error:(NSError**)error
    {
    // +dataWithContentsOfFile:options:error: is absent in GNUstep 1.31; the plain
    // form is universal (nil on failure, no NSError detail).
    NSData* data = [NSData dataWithContentsOfFile:path];
    if (!data)
        {
        if (error)
            *error = [NSError errorWithDomain:@"XTDwarfReader"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey :
                                                    [NSString stringWithFormat:@"cannot read '%@'", path]}];
        return nil;
        }
    // Construct the reader here (rather than via readInterfaceFromData:) so it
    // knows the on-disk path — a Mach-O dylib usually carries no DWARF itself
    // (Darwin leaves it in a sibling `.dSYM`), which we can only find by path.
    XTDwarfReader* r = [[XTDwarfReader alloc] init];
    r->_diskPath = path;
    XTDwarfInterface* iface = [r readImage:data
                                      name:path.lastPathComponent
                        targetPointerWidth:ptrWidth
                                     error:error];
    iface.sourcePath = path; // link against this so ld records DT_NEEDED
    return iface;
    }

+ (nullable XTDwarfInterface*)readInterfaceFromData:(NSData*)data
                                               name:(NSString*)displayName
                                 targetPointerWidth:(NSUInteger)ptrWidth
                                              error:(NSError**)error
    {
    XTDwarfReader* r = [[XTDwarfReader alloc] init];
    return [r readImage:data name:displayName targetPointerWidth:ptrWidth error:error];
    }

- (nullable XTDwarfInterface*)readImage:(NSData*)data
                                   name:(NSString*)displayName
                     targetPointerWidth:(NSUInteger)ptrWidth
                                  error:(NSError**)error
    {
    _ptrWidth = ptrWidth ?: 2;
    _image = data;
    _bytes = data.bytes;
    _len = data.length;
    _sections = [NSMutableDictionary dictionary];
    _dieByOffset = [NSMutableDictionary dictionary];
    _typeCache = [NSMutableDictionary dictionary];
    _namedTypes = [NSMutableDictionary dictionary];
    _inProgress = [NSMutableSet set];

    // Dispatch on the container magic. ELF and Mach-O both funnel into the same
    // `_sections` dict + DWARF walker; only the front matter (section table,
    // export list, soname) differs per format.
    NSString* soname;
    NSSet<NSString*>* exports;
    if (_len >= 4 && memcmp(_bytes, "\x7f"
                                    "ELF",
                            4) == 0)
        {
        if (![self parseELF:error])
            return nil;
        soname = [self readSonameOrDefault:displayName];
        exports = [self readDynsymExports];
        }
    else if ([self looksLikeMachO])
        {
        if (![self parseMachO:error])
            return nil;
        soname = displayName; // Mach-O has no DT_SONAME
        exports = [self readMachOExports];
        // A shipped dylib usually carries no DWARF (Darwin's ld leaves it in the
        // .o's + a debug map; dsymutil gathers it into a sibling `.dSYM`). When
        // the dylib has no __debug_* sections, read them from that `.dSYM`.
        if (!_sections[@".debug_info"] && _diskPath)
            {
            NSString* dwarf = [self locateDsymDwarfFor:_diskPath];
            NSData* dd = dwarf ? [NSData dataWithContentsOfFile:dwarf] : nil;
            if (dd)
                {
                _image = dd;
                _bytes = dd.bytes;
                _len = dd.length;
                _sections = [NSMutableDictionary dictionary];
                [self parseMachO:NULL]; // fill _sections from the dSYM's __DWARF
                }
            }
        }
    else
        {
        [self failWithError:error message:@"unrecognised object file (not ELF or Mach-O)"];
        return nil;
        }

    // DWARF may be absent (a stripped runtime build). That's still a valid
    // object — we just can't type anything. Return names-only.
    NSArray<NSNumber*>* info = _sections[@".debug_info"];
    if (!info)
        {
        return [[XTDwarfInterface alloc] initWithSoname:soname
                                                exports:exports
                                              functions:@[]
                                                  types:@{}];
        }
    [self setupDwarfCursors];
    [self parseAllCompilationUnits];

    NSArray<XTDwarfFunction*>* fns = [self buildFunctionsFilteredBy:exports];
    return [[XTDwarfInterface alloc] initWithSoname:soname
                                            exports:exports
                                          functions:fns
                                              types:_namedTypes
                                      enumConstants:[self collectEnumConstants]];
    }

/****************************************************************************\
|* Every enumerator in the DWARF, named enum or not.
|*
|* Swept from ALL DIEs rather than followed through type references, because a
|* C header's constants are routinely declared as an ANONYMOUS enum:
|*
|*     enum { G_BOX = 20, ..., G_USERDEF = 24 };
|*
|* Nothing ever references that enum's type, so mapEnumType: is never reached
|* for it and its constants were simply invisible on import — every binding had
|* to hand-mirror them and silently drifted when the header changed.
\****************************************************************************/
- (NSDictionary<NSString*, NSNumber*>*)collectEnumConstants
    {
    NSMutableDictionary<NSString*, NSNumber*>* out = [NSMutableDictionary dictionary];
    for (NSNumber* off in _dieByOffset)
        {
        XTDwDIE* die = _dieByOffset[off];
        if (die->tag != DW_TAG_enumeration_type)
            continue;
        for (XTDwDIE* child in die->children)
            {
            if (child->tag != DW_TAG_enumerator || !child->name.length)
                continue;
            out[child->name] = @(child->hasConstValue ? child->constValue : 0);
            }
        }
    return out;
    }

// ───────────────────────────── ELF parse ────────────────────────────────

- (BOOL)failWithError:(NSError**)error message:(NSString*)msg
    {
    if (error)
        *error = [NSError errorWithDomain:XTDwarfErrorDomain
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey : msg}];
    return NO;
    }

- (BOOL)parseELF:(NSError**)error
    {
    if (_len < 64 || memcmp(_bytes, "\x7f"
                                    "ELF",
                            4) != 0)
        return [self failWithError:error message:@"not an ELF file"];
    _elfClass = _bytes[4];  // EI_CLASS
    _le = (_bytes[5] == 1); // EI_DATA: 1 = LE
    if (_elfClass != 1 && _elfClass != 2)
        return [self failWithError:error message:@"unknown ELF class"];

    Cur c = {_bytes, _bytes, _bytes + _len, _le, YES};
    uint64_t shoff;
    uint16_t shentsize, shnum, shstrndx;
    // ELF32 header
    if (_elfClass == 1)
        {
        c.p = _bytes + 0x20;
        shoff = rdU32(&c);
        c.p = _bytes + 0x2e;
        shentsize = rdU16(&c);
        shnum = rdU16(&c);
        shstrndx = rdU16(&c);
        }
    // ELF64 header
    else
        {
        c.p = _bytes + 0x28;
        shoff = rdU64(&c);
        c.p = _bytes + 0x3a;
        shentsize = rdU16(&c);
        shnum = rdU16(&c);
        shstrndx = rdU16(&c);
        }
    if (!c.ok || shoff == 0 || shnum == 0 || shoff + (uint64_t)shentsize * shnum > _len)
        return [self failWithError:error message:@"bad section header table"];

    // Read raw section records first (name is an index into .shstrtab).
    NSMutableArray<NSArray<NSNumber*>*>* raw = [NSMutableArray array]; // [nameIdx, type, off, size, link, entsize]
    for (uint16_t i = 0; i < shnum; i++)
        {
        Cur s = {_bytes, _bytes + shoff + (uint64_t)i * shentsize, _bytes + _len, _le, YES};
        uint32_t nameIdx = rdU32(&s);
        uint32_t type;
        uint64_t off, size, link, entsz;
        if (_elfClass == 1)
            {
            type = rdU32(&s);
            (void)rdU32(&s);
            (void)rdU32(&s); // flags, addr
            off = rdU32(&s);
            size = rdU32(&s);
            link = rdU32(&s);
            (void)rdU32(&s);
            (void)rdU32(&s);
            entsz = rdU32(&s); // info, align, entsize
            }
        else
            {
            type = rdU32(&s);
            (void)rdU64(&s);
            (void)rdU64(&s); // flags, addr
            off = rdU64(&s);
            size = rdU64(&s);
            link = rdU32(&s);
            (void)rdU32(&s);
            (void)rdU64(&s);
            entsz = rdU64(&s); // info, align, entsize
            }
        [raw addObject:@[ @(nameIdx), @(type), @(off), @(size), @(link), @(entsz) ]];
        }
    if (shstrndx >= raw.count)
        return [self failWithError:error message:@"bad shstrndx"];
    uint64_t strOff = raw[shstrndx][2].unsignedLongLongValue;
    uint64_t strSize = raw[shstrndx][3].unsignedLongLongValue;
    if (strOff + strSize > _len)
        return [self failWithError:error message:@"bad shstrtab"];

    for (NSArray<NSNumber*>* rec in raw)
        {
        uint64_t nameIdx = rec[0].unsignedLongLongValue;
        NSString* nm = [self cStringAt:strOff + nameIdx limit:strOff + strSize];
        if (nm.length)
            _sections[nm] = @[ rec[2], rec[3], rec[4], rec[1], rec[5] ]; // off,size,link,type,entsize
        }
    return YES;
    }

// Read a NUL-terminated ASCII string at absolute file offset `off`, bounded.
- (NSString*)cStringAt:(uint64_t)off limit:(uint64_t)limit
    {
    if (off >= _len || off >= limit)
        return @"";
    uint64_t cap = MIN(limit, (uint64_t)_len);
    uint64_t e = off;
    while (e < cap && _bytes[e] != 0)
        e++;
    if (e == off)
        return @"";
    return [[NSString alloc] initWithBytes:_bytes + off
                                    length:(NSUInteger)(e - off)
                                  encoding:NSUTF8StringEncoding]
               ?: @"";
    }

// ───────────────────────────── Mach-O parse ─────────────────────────────
//
// The container-agnostic half of the reader keys off `_sections` (name →
// off/size) and the `exports` set; Mach-O just fills those from a different
// on-disk shape. We support 64-bit Mach-O (MH_MAGIC_64 / MH_CIGAM_64) — the
// only kind clang emits for xtc's native (arm64 / x86-64) targets.

// Mach-O magics + load commands we touch
enum
    {
    MH_MAGIC_64 = 0xFEEDFACF,
    MH_CIGAM_64 = 0xCFFAEDFE,
    LC_SEGMENT_64 = 0x19,
    LC_SYMTAB = 0x02,
    N_STAB = 0xe0,
    N_TYPE = 0x0e,
    N_EXT = 0x01,
    N_SECT = 0x0e,
    };

- (BOOL)looksLikeMachO
    {
    if (_len < 4)
        return NO;
    uint32_t m = _bytes[0] | (_bytes[1] << 8) | (_bytes[2] << 16) | ((uint32_t)_bytes[3] << 24);
    return m == MH_MAGIC_64 || m == MH_CIGAM_64;
    }

// Normalise a Mach-O DWARF section name (`__debug_info`) to the ELF spelling
// (`.debug_info`) the DWARF walker downstream looks up.
static NSString* normDwarfSectionName(const char* sect)
    {
    NSString* raw = [NSString stringWithUTF8String:sect] ?: @"";
    // Mach-O section names cap at 16 chars, so `__debug_str_offsets` arrives
    // truncated as `__debug_str_offs` — map it back to the ELF spelling.
    if ([raw isEqualToString:@"__debug_str_offs"])
        return @".debug_str_offsets";
    return [raw hasPrefix:@"__"] ? [@"." stringByAppendingString:[raw substringFromIndex:2]] : raw;
    }

- (BOOL)parseMachO:(NSError**)error
    {
    if (_len < 32)
        return [self failWithError:error message:@"truncated Mach-O header"];
    uint32_t magic = _bytes[0] | (_bytes[1] << 8) | (_bytes[2] << 16) | ((uint32_t)_bytes[3] << 24);
    _le = (magic == MH_MAGIC_64); // CIGAM ⇒ byte-swapped (big-endian file)
    _elfClass = 2;                // 64-bit; keeps any width logic 64-bit-safe

    Cur c = {_bytes, _bytes + 16, _bytes + _len, _le, YES}; // magic..reserved is 32 bytes
    uint32_t ncmds = rdU32(&c);                             // header+16: ncmds
    // Load commands start right after the 32-byte mach_header_64.
    uint64_t lcOff = 32;
    for (uint32_t i = 0; i < ncmds && lcOff + 8 <= _len; i++)
        {
        Cur lc = {_bytes, _bytes + lcOff, _bytes + _len, _le, YES};
        uint32_t cmd = rdU32(&lc), cmdsize = rdU32(&lc);
        if (cmdsize < 8 || lcOff + cmdsize > _len)
            break;

        if (cmd == LC_SEGMENT_64)
            {
            char seg[17] = {0};
            memcpy(seg, _bytes + lcOff + 8, 16); // segname[16]
            // segment_command_64: cmd,cmdsize,segname[16],vmaddr,vmsize,fileoff,
            // filesize (4×u64), maxprot,initprot (2×u32), nsects, flags (2×u32).
            Cur sc = {_bytes, _bytes + lcOff + 8 + 16 + 4 * 8 + 2 * 4, _bytes + _len, _le, YES};
            uint32_t nsects = rdU32(&sc);
            BOOL isDwarf = (strcmp(seg, "__DWARF") == 0);
            uint64_t secBase = lcOff + 72; // sections follow the 72-byte segment cmd
            for (uint32_t s = 0; isDwarf && s < nsects; s++)
                {
                uint64_t rec = secBase + (uint64_t)s * 80; // section_64 is 80 bytes
                if (rec + 80 > _len)
                    break;
                char sect[17] = {0};
                memcpy(sect, _bytes + rec, 16);                               // sectname[16]
                Cur f = {_bytes, _bytes + rec + 32, _bytes + _len, _le, YES}; // past sect+seg names
                (void)rdU64(&f);                                              // addr
                uint64_t size = rdU64(&f);
                uint32_t off = rdU32(&f); // section file offset
                _sections[normDwarfSectionName(sect)] = @[ @(off), @(size), @0, @0, @0 ];
                }
            }
        else if (cmd == LC_SYMTAB)
            {
            _machoSymOff = rdU32(&lc);
            _machoNSyms = rdU32(&lc);
            _machoStrOff = rdU32(&lc);
            _machoStrSize = rdU32(&lc);
            }
        lcOff += cmdsize;
        }
    return YES;
    }

// Exported, defined symbols from LC_SYMTAB. Mach-O prefixes C symbols with an
// underscore (`_foo`); strip it so the name matches the DWARF DW_AT_name (`foo`)
// that buildFunctionsFilteredBy: keys on.
- (NSSet<NSString*>*)readMachOExports
    {
    NSMutableSet<NSString*>* out = [NSMutableSet set];
    const uint64_t NLIST_64 = 16;
    for (uint64_t i = 0; i < _machoNSyms; i++)
        {
        uint64_t base = _machoSymOff + i * NLIST_64;
        if (base + NLIST_64 > _len)
            break;
        Cur s = {_bytes, _bytes + base, _bytes + _len, _le, YES};
        uint32_t strx = rdU32(&s);
        uint8_t ntype = rdU8(&s);
        if (!s.ok)
            break;
        if (ntype & N_STAB)
            continue; // debug-map stab, not a real symbol
        if (!(ntype & N_EXT))
            continue; // not exported
        if ((ntype & N_TYPE) != N_SECT)
            continue; // not defined in a section here
        NSString* nm = [self cStringAt:_machoStrOff + strx limit:_machoStrOff + _machoStrSize];
        if ([nm hasPrefix:@"_"])
            nm = [nm substringFromIndex:1];
        if (nm.length)
            [out addObject:nm];
        }
    return out;
    }

// Sibling `.dSYM` DWARF binary for a dylib: foo.dylib →
// foo.dylib.dSYM/Contents/Resources/DWARF/foo.dylib. Returns nil if absent.
- (NSString*)locateDsymDwarfFor:(NSString*)path
    {
    NSString* dwarf = [NSString stringWithFormat:@"%@.dSYM/Contents/Resources/DWARF/%@",
                                                 path, path.lastPathComponent];
    return [[NSFileManager defaultManager] fileExistsAtPath:dwarf] ? dwarf : nil;
    }

// ──────────────────────── .dynamic / .dynsym ─────────────────────────────

- (NSString*)readSonameOrDefault:(NSString*)displayName
    {
    NSArray<NSNumber*>* dyn = _sections[@".dynamic"];
    NSArray<NSNumber*>* dynstr = _sections[@".dynstr"];
    if (dyn && dynstr)
        {
        uint64_t off = dyn[0].unsignedLongLongValue, size = dyn[1].unsignedLongLongValue;
        uint64_t strOff = dynstr[0].unsignedLongLongValue, strSize = dynstr[1].unsignedLongLongValue;
        Cur c = {_bytes, _bytes + off, _bytes + MIN((uint64_t)_len, off + size), _le, YES};
        int wsz = (_elfClass == 1) ? 4 : 8;
        while (c.ok && c.p + 2 * wsz <= c.end)
            {
            uint64_t tag = rdN(&c, wsz), val = rdN(&c, wsz);
            if (tag == DT_NULL)
                break;
            if (tag == DT_SONAME)
                {
                NSString* s = [self cStringAt:strOff + val limit:strOff + strSize];
                if (s.length)
                    return s;
                }
            }
        }
    return displayName;
    }

- (NSSet<NSString*>*)readDynsymExports
    {
    NSMutableSet<NSString*>* out = [NSMutableSet set];
    NSArray<NSNumber*>* sym = _sections[@".dynsym"];
    if (!sym)
        return out;
    uint64_t off = sym[0].unsignedLongLongValue, size = sym[1].unsignedLongLongValue;
    uint64_t link = sym[2].unsignedLongLongValue;
    // The symbol table's string table is its sh_link section.
    uint64_t strOff = 0, strSize = 0;
    NSArray<NSNumber*>* strs = _sections[@".dynstr"];
    if (strs)
        {
        strOff = strs[0].unsignedLongLongValue;
        strSize = strs[1].unsignedLongLongValue;
        }
    (void)link;
    int symsz = (_elfClass == 1) ? 16 : 24;
    uint64_t n = size / symsz;
    for (uint64_t i = 0; i < n; i++)
        {
        Cur s = {_bytes, _bytes + off + i * symsz, _bytes + _len, _le, YES};
        uint32_t nameIdx;
        uint8_t info;
        uint16_t shndx;
        if (_elfClass == 1)
            {
            nameIdx = rdU32(&s);
            (void)rdU32(&s);
            (void)rdU32(&s); // value, size
            info = rdU8(&s);
            (void)rdU8(&s);
            shndx = rdU16(&s); // info, other, shndx
            }
        else
            {
            nameIdx = rdU32(&s);
            info = rdU8(&s);
            (void)rdU8(&s); // name, info, other
            shndx = rdU16(&s);
            (void)rdU64(&s);
            (void)rdU64(&s); // shndx, value, size
            }
        if (!s.ok)
            break;
        uint8_t bind = info >> 4, type = info & 0xf;
        if (shndx == SHN_UNDEF)
            continue; // imported, not exported
        if (bind != STB_GLOBAL && bind != STB_WEAK)
            continue;
        if (type != STT_FUNC && type != STT_OBJECT)
            continue;
        NSString* nm = [self cStringAt:strOff + nameIdx limit:strOff + strSize];
        if (nm.length)
            [out addObject:nm];
        }
    return out;
    }

// ───────────────────────────── DWARF walk ───────────────────────────────

- (Cur)cursorForSection:(NSString*)name
    {
    NSArray<NSNumber*>* s = _sections[name];
    if (!s)
        return (Cur){NULL, NULL, NULL, _le, NO};
    uint64_t off = s[0].unsignedLongLongValue, size = s[1].unsignedLongLongValue;
    if (off + size > _len)
        return (Cur){NULL, NULL, NULL, _le, NO};
    const uint8_t* b = _bytes + off;
    return (Cur){b, b, b + size, _le, YES};
    }

- (void)setupDwarfCursors
    {
    _info = [self cursorForSection:@".debug_info"];
    _abbrev = [self cursorForSection:@".debug_abbrev"];
    _str = [self cursorForSection:@".debug_str"];
    _lineStr = [self cursorForSection:@".debug_line_str"];
    _strOffsets = [self cursorForSection:@".debug_str_offsets"];
    }

// Resolve a DWARF5 DW_FORM_strx index: .debug_str_offsets[idx] is an offset
// into .debug_str. We assume clang's single-CU DWARF32 layout — an 8-byte
// section header (unit_length, version, padding) then 4-byte entries — which
// is what DW_AT_str_offsets_base points past.
- (NSString*)strxAt:(uint64_t)idx
    {
    if (!_strOffsets.base)
        return nil;
    uint64_t pos = 8 + idx * 4; // past the 8-byte header
    if (pos + 4 > (uint64_t)(_strOffsets.end - _strOffsets.base))
        return nil;
    Cur t = _strOffsets;
    t.p = t.base + pos;
    uint32_t strOff = rdU32(&t);
    return [self strAt:strOff inSection:&_str];
    }

// Parse the abbrev table starting at `abbrevOffset`; returns code → abbrev.
- (NSDictionary<NSNumber*, XTDwAbbrev*>*)parseAbbrevTableAt:(uint64_t)abbrevOffset
    {
    NSMutableDictionary<NSNumber*, XTDwAbbrev*>* table = [NSMutableDictionary dictionary];
    Cur c = _abbrev;
    if (!c.base)
        return table;
    c.p = c.base + abbrevOffset;
    while (c.ok && c.p < c.end)
        {
        uint64_t code = rdULEB(&c);
        if (code == 0)
            break; // end of this table
        XTDwAbbrev* ab = [[XTDwAbbrev alloc] init];
        ab->tag = (uint32_t)rdULEB(&c);
        ab->hasChildren = (rdU8(&c) != 0);
        while (c.ok)
            {
            uint64_t at = rdULEB(&c), form = rdULEB(&c);
            int64_t implicit = 0;
            if (form == DW_FORM_implicit_const)
                implicit = rdSLEB(&c);
            if (at == 0 && form == 0)
                break;
            [ab->attrs addObject:@(at)];
            [ab->attrs addObject:@(form)];
            [ab->attrs addObject:@(implicit)];
            }
        table[@(code)] = ab;
        }
    return table;
    }

- (void)parseAllCompilationUnits
    {
    Cur c = _info;
    if (!c.base)
        return;
    while (c.ok && c.p + 4 <= c.end)
        {
        uint64_t cuStart = (uint64_t)(c.p - c.base);
        uint32_t unitLen = rdU32(&c);
        if (unitLen == 0xffffffff)
            break; // 64-bit DWARF unsupported
        const uint8_t* cuEnd = c.p + unitLen;
        if (cuEnd > c.end)
            cuEnd = c.end;
        uint16_t version = rdU16(&c);
        uint64_t abbrevOff;
        uint8_t addrSize;
        if (version >= 5)
            {
            (void)rdU8(&c); // unit_type
            addrSize = rdU8(&c);
            abbrevOff = rdU32(&c);
            }
        else
            {
            abbrevOff = rdU32(&c);
            addrSize = rdU8(&c);
            }
        NSDictionary<NSNumber*, XTDwAbbrev*>* abbrev = [self parseAbbrevTableAt:abbrevOff];

        // Walk DIEs in this CU.
        Cur d = c;
        d.end = cuEnd;
        [self walkDIEsInto:nil
                    cursor:&d
                   cuStart:cuStart
                  addrSize:addrSize
                   version:version
                    abbrev:abbrev];
        c.p = cuEnd;
        }
    }

// Recursively parse a sibling chain. Returns when a null DIE (code 0) ends
// the chain. Top-level call passes parent=nil.
- (void)walkDIEsInto:(nullable XTDwDIE*)parent
              cursor:(Cur*)c
             cuStart:(uint64_t)cuStart
            addrSize:(uint8_t)addrSize
             version:(uint16_t)version
              abbrev:(NSDictionary<NSNumber*, XTDwAbbrev*>*)abbrev
    {
    while (c->ok && c->p < c->end)
        {
        uint64_t dieOff = (uint64_t)(c->p - c->base);
        uint64_t code = rdULEB(c);
        if (code == 0)
            return; // end of sibling chain
        XTDwAbbrev* ab = abbrev[@(code)];
        if (!ab)
            {
            c->ok = NO;
            return;
            }

        XTDwDIE* die = [[XTDwDIE alloc] init];
        die->offset = dieOff;
        die->tag = ab->tag;
        _dieByOffset[@(dieOff)] = die;

        for (NSUInteger i = 0; i + 2 < ab->attrs.count; i += 3)
            {
            uint64_t at = ab->attrs[i].unsignedLongLongValue;
            uint64_t form = ab->attrs[i + 1].unsignedLongLongValue;
            int64_t implicit = ab->attrs[i + 2].longLongValue;
            [self readAttr:at
                      form:form
                  implicit:implicit
                      into:die
                    cursor:c
                   cuStart:cuStart
                  addrSize:addrSize
                   version:version];
            }
        if (parent)
            [parent->children addObject:die];

        if (ab->hasChildren)
            {
            [self walkDIEsInto:die
                        cursor:c
                       cuStart:cuStart
                      addrSize:addrSize
                       version:version
                        abbrev:abbrev];
            }
        }
    }

// Decode one attribute value by its FORM, advancing the cursor. Only the
// attributes we consume are retained on the DIE; everything else is read
// purely to keep the cursor aligned.
- (void)readAttr:(uint64_t)at form:(uint64_t)form implicit:(int64_t)implicit
            into:(XTDwDIE*)die
          cursor:(Cur*)c
         cuStart:(uint64_t)cuStart
        addrSize:(uint8_t)addrSize
         version:(uint16_t)version
    {
    NSString* strVal = nil;
    BOOL haveU = NO;
    uint64_t uVal = 0;
    BOOL haveS = NO;
    int64_t sVal = 0;
    BOOL haveRef = NO;
    uint64_t refVal = 0; // absolute .debug_info offset
    BOOL flagVal = NO;
    BOOL haveFlag = NO;

    switch (form)
        {
    case DW_FORM_addr:
        uVal = rdN(c, addrSize ? addrSize : 4);
        haveU = YES;
        break;
    case DW_FORM_data1:
        uVal = rdU8(c);
        haveU = YES;
        break;
    case DW_FORM_data2:
        uVal = rdU16(c);
        haveU = YES;
        break;
    case DW_FORM_data4:
        uVal = rdU32(c);
        haveU = YES;
        break;
    case DW_FORM_data8:
        uVal = rdU64(c);
        haveU = YES;
        break;
    case DW_FORM_data16:
        c->p += 16;
        if (!curHas(c, 0))
            {
            }
        break;
    case DW_FORM_udata:
        uVal = rdULEB(c);
        haveU = YES;
        break;
    case DW_FORM_sdata:
        sVal = rdSLEB(c);
        haveS = YES;
        break;
    case DW_FORM_sec_offset:
        uVal = rdU32(c);
        haveU = YES;
        break;
    case DW_FORM_strp:
        {
        uint32_t o = rdU32(c);
        strVal = [self strAt:o inSection:&_str];
        break;
        }
    case DW_FORM_line_strp:
        {
        uint32_t o = rdU32(c);
        strVal = [self strAt:o inSection:&_lineStr];
        break;
        }
    case DW_FORM_string:
        {
        const uint8_t* s = c->p;
        while (c->ok && c->p < c->end && *c->p)
            c->p++;
        NSUInteger n = (NSUInteger)(c->p - s);
        if (c->p < c->end)
            c->p++; // consume NUL
        strVal = n ? [[NSString alloc] initWithBytes:s length:n encoding:NSUTF8StringEncoding] : @"";
        break;
        }
    case DW_FORM_flag:
        flagVal = (rdU8(c) != 0);
        haveFlag = YES;
        break;
    case DW_FORM_flag_present:
        flagVal = YES;
        haveFlag = YES;
        break;
    case DW_FORM_ref1:
        refVal = cuStart + rdU8(c);
        haveRef = YES;
        break;
    case DW_FORM_ref2:
        refVal = cuStart + rdU16(c);
        haveRef = YES;
        break;
    case DW_FORM_ref4:
        refVal = cuStart + rdU32(c);
        haveRef = YES;
        break;
    case DW_FORM_ref8:
        refVal = cuStart + rdU64(c);
        haveRef = YES;
        break;
    case DW_FORM_ref_udata:
        refVal = cuStart + rdULEB(c);
        haveRef = YES;
        break;
    case DW_FORM_ref_addr:
        refVal = rdU32(c);
        haveRef = YES;
        break;
    case DW_FORM_ref_sig8:
        (void)rdU64(c);
        break;
    case DW_FORM_ref_sup4:
        (void)rdU32(c);
        break;
    case DW_FORM_ref_sup8:
        (void)rdU64(c);
        break;
    case DW_FORM_strp_sup:
        (void)rdU32(c);
        break;
    case DW_FORM_exprloc:
        {
        uint64_t n = rdULEB(c);
        [self consumeBlock:c
                    length:n
               asMemberLoc:(at == DW_AT_data_member_location)
                      into:die];
        break;
        }
    case DW_FORM_block1:
        {
        uint64_t n = rdU8(c);
        [self consumeBlock:c
                    length:n
               asMemberLoc:(at == DW_AT_data_member_location)
                      into:die];
        break;
        }
    case DW_FORM_block2:
        {
        uint64_t n = rdU16(c);
        [self consumeBlock:c
                    length:n
               asMemberLoc:(at == DW_AT_data_member_location)
                      into:die];
        break;
        }
    case DW_FORM_block4:
        {
        uint64_t n = rdU32(c);
        [self consumeBlock:c
                    length:n
               asMemberLoc:(at == DW_AT_data_member_location)
                      into:die];
        break;
        }
    case DW_FORM_block:
        {
        uint64_t n = rdULEB(c);
        [self consumeBlock:c
                    length:n
               asMemberLoc:(at == DW_AT_data_member_location)
                      into:die];
        break;
        }
    case DW_FORM_implicit_const:
        sVal = implicit;
        haveS = YES;
        uVal = (uint64_t)implicit;
        haveU = YES;
        break;
    // DWARF5 string-index forms: resolve through .debug_str_offsets. clang
    // emits DW_AT_name as DW_FORM_strx on Mac, so this is load-bearing there.
    case DW_FORM_strx:
        strVal = [self strxAt:rdULEB(c)];
        break;
    case DW_FORM_strx1:
        strVal = [self strxAt:rdU8(c)];
        break;
    case DW_FORM_strx2:
        strVal = [self strxAt:rdU16(c)];
        break;
    case DW_FORM_strx3:
        strVal = [self strxAt:rdN(c, 3)];
        break;
    case DW_FORM_strx4:
        strVal = [self strxAt:rdU32(c)];
        break;
    // Address-index / list-index forms: payload we don't need, just size-skip.
    case DW_FORM_addrx1:
        (void)rdU8(c);
        break;
    case DW_FORM_addrx2:
        (void)rdU16(c);
        break;
    case DW_FORM_addrx3:
        (void)rdN(c, 3);
        break;
    case DW_FORM_addrx4:
        (void)rdU32(c);
        break;
    case DW_FORM_addrx:
    case DW_FORM_loclistx:
    case DW_FORM_rnglistx:
        (void)rdULEB(c);
        break;
    case DW_FORM_indirect:
        {
        uint64_t real = rdULEB(c);
        [self readAttr:at
                  form:real
              implicit:0
                  into:die
                cursor:c
               cuStart:cuStart
              addrSize:addrSize
               version:version];
        return;
        }
    default:
        c->ok = NO;
        return; // unknown form: stop, don't desync
        }

    switch (at)
        {
    case DW_AT_name:
        if (strVal)
            die->name = strVal;
        break;
    case DW_AT_linkage_name:
        if (strVal)
            die->linkageName = strVal;
        break;
    case DW_AT_type:
        if (haveRef)
            {
            die->hasType = YES;
            die->typeRef = refVal;
            }
        break;
    case DW_AT_byte_size:
        if (haveU)
            {
            die->hasByteSize = YES;
            die->byteSize = uVal;
            }
        break;
    case DW_AT_encoding:
        if (haveU)
            die->encoding = uVal;
        break;
    case DW_AT_data_member_location:
        if (haveU && !die->hasMemberLoc)
            {
            die->hasMemberLoc = YES;
            die->memberLoc = uVal;
            }
        break;
    case DW_AT_const_value:
        die->hasConstValue = YES;
        die->constValue = haveS ? sVal : (int64_t)uVal;
        break;
    case DW_AT_upper_bound:
        if (haveU)
            {
            die->hasCount = YES;
            die->count = uVal + 1;
            }
        else if (haveS && sVal >= 0)
            {
            die->hasCount = YES;
            die->count = (uint64_t)sVal + 1;
            }
        break;
    case DW_AT_count:
        if (haveU)
            {
            die->hasCount = YES;
            die->count = uVal;
            }
        break;
    case DW_AT_external:
        if (haveFlag)
            die->external = flagVal;
        break;
    case DW_AT_declaration:
        if (haveFlag)
            die->declaration = flagVal;
        break;
    default:
        break;
        }
    }

// A location/expression block. For DW_AT_data_member_location it may be a
// `DW_OP_plus_uconst <off>` expression — decode that one case to recover the
// member byte offset; otherwise ignore the bytes.
- (void)consumeBlock:(Cur*)c length:(uint64_t)n asMemberLoc:(BOOL)isMemberLoc into:(XTDwDIE*)die
    {
    if (n == 0)
        return;
    if (!curHas(c, (size_t)n))
        {
        c->ok = NO;
        return;
        }
    const uint8_t* blk = c->p;
    if (isMemberLoc && !die->hasMemberLoc && blk[0] == DW_OP_plus_uconst)
        {
        Cur b = {blk, blk + 1, blk + n, c->le, YES};
        uint64_t off = rdULEB(&b);
        die->hasMemberLoc = YES;
        die->memberLoc = off;
        }
    c->p += n;
    }

- (NSString*)strAt:(uint64_t)off inSection:(Cur*)sec
    {
    if (!sec->base)
        return @"";
    const uint8_t* s = sec->base + off;
    if (s >= sec->end)
        return @"";
    const uint8_t* e = s;
    while (e < sec->end && *e)
        e++;
    if (e == s)
        return @"";
    return [[NSString alloc] initWithBytes:s
                                    length:(NSUInteger)(e - s)
                                  encoding:NSUTF8StringEncoding]
               ?: @"";
    }

// ─────────────────── DWARF type DIE → xtc XTType ─────────────────────────

- (nullable XTType*)typeForRef:(uint64_t)ref
    {
    XTDwDIE* die = _dieByOffset[@(ref)];
    if (!die)
        return nil;
    return [self typeForDIE:die];
    }

- (nullable XTType*)typeForDIE:(XTDwDIE*)die
    {
    NSNumber* key = @(die->offset);
    XTType* cached = _typeCache[key];
    if (cached)
        return cached;
    if ([_inProgress containsObject:key])
        return nil; // mid-construction cycle

    switch (die->tag)
        {
    case DW_TAG_base_type:
        return [self mapBaseType:die];
    case DW_TAG_pointer_type:
        return [self mapPointerType:die];
    case DW_TAG_typedef:
        return [self mapTypedef:die];
    case DW_TAG_const_type:
    case DW_TAG_volatile_type:
    case DW_TAG_restrict_type:
        return die->hasType ? [self typeForRef:die->typeRef] : XTType.voidType;
    case DW_TAG_structure_type:
        return [self mapStructType:die isUnion:NO];
    case DW_TAG_union_type:
        return [self mapStructType:die isUnion:YES];
    case DW_TAG_enumeration_type:
        return [self mapEnumType:die];
    case DW_TAG_array_type:
        return [self mapArrayType:die];
    case DW_TAG_subroutine_type:
        return [self mapSubroutineType:die];
    default:
        return nil;
        }
    }

- (XTType*)mapBaseType:(XTDwDIE*)die
    {
    uint64_t sz = die->hasByteSize ? die->byteSize : 0;
    XTType* t;
    switch (die->encoding)
        {
    case DW_ATE_boolean:
        t = XTType.boolType;
        break;
    case DW_ATE_float:
        t = (sz >= 8) ? XTType.doubleType : XTType.floatType;
        break;
    case DW_ATE_signed:
    case DW_ATE_signed_char:
        t = (sz <= 1) ? XTType.i8Type : (sz == 2) ? XTType.i16Type
                                                  : XTType.i32Type;
        break;
    case DW_ATE_unsigned:
    case DW_ATE_unsigned_char:
    default:
        t = (sz <= 1) ? XTType.u8Type : (sz == 2) ? XTType.u16Type
                                                  : XTType.u32Type;
        break;
        }
    _typeCache[@(die->offset)] = t;
    return t;
    }

- (XTType*)mapPointerType:(XTDwDIE*)die
    {
    // Resolve the pointee first, THEN cache the typed pointer. We must NOT
    // pre-cache a bare placeholder: a self-referential struct's field
    // (`struct node *next`) re-enters this same pointer DIE while the struct
    // is mid-construction, and would capture the placeholder instead of the
    // typed `node@`. The cycle is already broken by mapStructType, which
    // caches the (empty) struct before resolving its fields — every C
    // recursive type closes through an aggregate, so the pointee lookup hits
    // that struct cache and returns a typed (in-progress) struct here.
    XTType* pointee = die->hasType ? [self typeForRef:die->typeRef] : XTType.voidType;
    if (!pointee)
        return XTType.pointerType; // truly incomplete → opaque handle
    XTType* ptr = [XTPointerType pointerToType:pointee];
    _typeCache[@(die->offset)] = ptr;
    return ptr;
    }

- (nullable XTType*)mapTypedef:(XTDwDIE*)die
    {
    XTType* underlying = die->hasType ? [self typeForRef:die->typeRef] : XTType.voidType;
    if (underlying)
        {
        _typeCache[@(die->offset)] = underlying;
        // `typedef struct { … } OBJECT;` — in C the typedef name IS the type's name.
        // The struct DIE is anonymous, so we had called it `$anon_<DIE offset>`, and
        // THAT is the name --emit-lib serialised into an interface. No client could
        // resolve it (its type table knows `OBJECT`), so a C type imported from
        // another library could not cross an xtc library's interface — which blocks
        // the whole category of BINDING library. Give it the name it actually has.
        if (die->name.length && [underlying isKindOfClass:[XTStructType class]])
            [(XTStructType*)underlying adoptTypedefName:die->name];
        if (die->name.length)
            [self recordNamedType:underlying as:die->name];
        }
    return underlying;
    }

// Honour DWARF layout VERBATIM: place each member at DW_AT_data_member_location
// and reconstruct C padding as explicit pad bytes, so xtc's tight-packing
// reproduces the exact offsets and DW_AT_byte_size total. A union is modelled
// as an opaque blob of byte_size (xtc has no union kind) — preserving size and
// every enclosing offset.
- (XTType*)mapStructType:(XTDwDIE*)die isUnion:(BOOL)isUnion
    {
    NSString* tag = die->name.length ? die->name : [NSString stringWithFormat:@"$anon_%llu", die->offset];
    uint64_t total = die->hasByteSize ? die->byteSize : 0;

    if (isUnion)
        {
        XTStructType* blob = [self opaqueBlobNamed:tag bytes:total];
        _typeCache[@(die->offset)] = blob;
        if (die->name.length)
            [self recordNamedType:blob as:die->name];
        return blob;
        }

    // Create the struct empty first and cache it so a self-referential member
    // (e.g. `struct node *next`) resolves to this same instance.
    // The DWARF-declared offsets are AUTHORITATIVE and arrive re-encoded as
    // explicit __padN fields, so the struct is marked :packed — tight packing
    // then reproduces the C offsets verbatim, and the natural-alignment
    // default (blewit #5) can never double-pad an imported layout.
    XTStructType* st = [XTStructType structNamed:tag fields:@[]];
    st.packed = YES;
    _typeCache[@(die->offset)] = st;
    [_inProgress addObject:@(die->offset)];

    NSMutableArray<XTStructField*>* fields = [NSMutableArray array];
    NSUInteger running = 0;
    int padSeq = 0;
    for (XTDwDIE* child in die->children)
        {
        if (child->tag != DW_TAG_member || !child->hasMemberLoc)
            continue;
        NSUInteger off = (NSUInteger)child->memberLoc;
        // leading gap → explicit pad
        if (off > running)
            {
            [fields addObject:[self padFieldBytes:(off - running) seq:padSeq++]];
            running = off;
            }
        else if (off < running)
            {
            // Overlap (a width we over-estimated). Trust DWARF: skip the field.
            continue;
            }
        XTType* ft = child->hasType ? [self typeForRef:child->typeRef] : XTType.u8Type;
        if (!ft)
            ft = XTType.pointerType;
        NSString* fname = child->name.length ? child->name
                                             : [NSString stringWithFormat:@"$f%llu", child->offset];
        // Clamp the field's footprint to the slot DWARF assigns it. If the
        // mapped type is wider than the next member allows, the next iteration
        // would otherwise overlap — handled there by the `off < running` skip,
        // but cap here so a too-wide pointer/scalar never eats a real member.
        NSUInteger slot = [self slotSpanForMemberAt:off inDie:die total:total];
        NSUInteger w = [self nativeWidthOf:ft];
        // can't fit the mapped type → opaque slot
        if (slot > 0 && w > slot)
            {
            [fields addObject:[self padFieldBytes:slot seq:padSeq++]];
            running = off + slot;
            continue;
            }
        XTStructField* f = [[XTStructField alloc] initWithName:fname type:ft];
        [fields addObject:f];
        running = off + w;
        }
    // trailing pad to DW_AT_byte_size
    if (total > running)
        {
        [fields addObject:[self padFieldBytes:(total - running) seq:padSeq++]];
        running = total;
        }
    [st replaceFields:fields];
    [_inProgress removeObject:@(die->offset)];
    if (die->name.length)
        [self recordNamedType:st as:die->name];
    return st;
    }

// The byte span allotted to the member starting at `off`: distance to the next
// member's offset, or to the struct total for the last member.
- (NSUInteger)slotSpanForMemberAt:(NSUInteger)off inDie:(XTDwDIE*)die total:(uint64_t)total
    {
    NSUInteger next = (NSUInteger)total;
    for (XTDwDIE* child in die->children)
        {
        if (child->tag != DW_TAG_member || !child->hasMemberLoc)
            continue;
        NSUInteger mo = (NSUInteger)child->memberLoc;
        if (mo > off && mo < next)
            next = mo;
        }
    return (next > off) ? (next - off) : 0;
    }

// The footprint a field occupies in the TARGET's native layout. Identical to
// byteWidth for fixed-size scalars/aggregates, but a pointer is the target's
// native pointer width (the backend re-sizes pointers, so pad math must too).
- (NSUInteger)nativeWidthOf:(XTType*)t
    {
    if (t.kind == XTTypeKindPointer)
        return _ptrWidth;
    return safeByteWidth(t);
    }

- (XTStructField*)padFieldBytes:(NSUInteger)n seq:(int)seq
    {
    XTType* pad = (n == 1) ? XTType.u8Type
                           : [XTArrayType arrayOfType:XTType.u8Type count:n];
    return [[XTStructField alloc] initWithName:[NSString stringWithFormat:@"__pad%d", seq] type:pad];
    }

- (XTStructType*)opaqueBlobNamed:(NSString*)name bytes:(uint64_t)n
    {
    NSArray<XTStructField*>* f = (n > 0)
                                     ? @[ [[XTStructField alloc] initWithName:@"__opaque"
                                                                         type:[XTArrayType arrayOfType:XTType.u8Type count:(NSUInteger)n]] ]
                                     : @[];
    return [XTStructType structNamed:name fields:f];
    }

- (XTType*)mapEnumType:(XTDwDIE*)die
    {
    NSMutableDictionary<NSString*, NSNumber*>* members = [NSMutableDictionary dictionary];
    for (XTDwDIE* child in die->children)
        {
        if (child->tag == DW_TAG_enumerator && child->name.length)
            members[child->name] = @(child->hasConstValue ? child->constValue : 0);
        }
    NSString* tag = die->name.length ? die->name : [NSString stringWithFormat:@"$enum_%llu", die->offset];
    XTType* t = [XTEnumType enumNamed:tag members:members];
    _typeCache[@(die->offset)] = t;
    if (die->name.length)
        [self recordNamedType:t as:die->name];
    return t;
    }

- (XTType*)mapArrayType:(XTDwDIE*)die
    {
    XTType* elem = die->hasType ? [self typeForRef:die->typeRef] : XTType.u8Type;
    if (!elem)
        elem = XTType.u8Type;
    NSUInteger count = 0;
    for (XTDwDIE* child in die->children)
        {
        if (child->tag == DW_TAG_subrange_type && child->hasCount)
            {
            count = (NSUInteger)child->count;
            break;
            }
        }
    XTType* t = [XTArrayType arrayOfType:elem count:count];
    _typeCache[@(die->offset)] = t;
    return t;
    }

- (XTType*)mapSubroutineType:(XTDwDIE*)die
    {
    XTType* ret = die->hasType ? [self typeForRef:die->typeRef] : XTType.voidType;
    if (!ret)
        ret = XTType.voidType;
    NSMutableArray<XTType*>* params = [NSMutableArray array];
    BOOL varargs = NO;
    for (XTDwDIE* child in die->children)
        {
        if (child->tag == DW_TAG_formal_parameter)
            {
            XTType* pt = child->hasType ? [self typeForRef:child->typeRef] : XTType.pointerType;
            [params addObject:(pt ?: XTType.pointerType)];
            }
        else if (child->tag == DW_TAG_unspecified_parameters)
            {
            varargs = YES;
            }
        }
    XTType* fn = [XTFunctionType functionWithReturnTypes:@[ ret ] paramTypes:params isVarArgs:varargs];
    XTType* ptr = [XTPointerType pointerToType:fn];
    _typeCache[@(die->offset)] = ptr;
    return ptr;
    }

- (void)recordNamedType:(XTType*)type as:(NSString*)name
    {
    if (!name.length || _namedTypes[name])
        return;
    // Only record "useful" named types (aggregates/enums); skip a typedef that
    // just aliases a scalar to its C spelling (e.g. uint16_t) — those would
    // collide with xtc's own names and add nothing.
    if (type.kind == XTTypeKindStruct || type.kind == XTTypeKindEnum)
        {
        _namedTypes[name] = type;
        }
    }

// ────────────────────── subprogram → XTDwarfFunction ─────────────────────

- (NSArray<XTDwarfFunction*>*)buildFunctionsFilteredBy:(NSSet<NSString*>*)exports
    {
    NSMutableDictionary<NSString*, XTDwarfFunction*>* best = [NSMutableDictionary dictionary];
    for (XTDwDIE* die in _dieByOffset.allValues)
        {
        if (die->tag != DW_TAG_subprogram)
            continue;
        NSString* nm = die->linkageName.length ? die->linkageName : die->name;
        if (!nm.length || ![exports containsObject:nm])
            continue;

        XTType* ret = die->hasType ? ([self typeForRef:die->typeRef] ?: XTType.voidType)
                                   : XTType.voidType;
        NSMutableArray<XTType*>* ptypes = [NSMutableArray array];
        NSMutableArray<NSString*>* pnames = [NSMutableArray array];
        BOOL varargs = NO;
        for (XTDwDIE* child in die->children)
            {
            if (child->tag == DW_TAG_formal_parameter)
                {
                XTType* pt = child->hasType ? [self typeForRef:child->typeRef] : XTType.pointerType;
                [ptypes addObject:(pt ?: XTType.pointerType)];
                [pnames addObject:(child->name.length ? child->name : @"")];
                }
            else if (child->tag == DW_TAG_unspecified_parameters)
                {
                varargs = YES;
                }
            }
        XTDwarfFunction* fn = [[XTDwarfFunction alloc] initWithName:nm
                                                         returnType:ret
                                                         paramTypes:ptypes
                                                         paramNames:pnames
                                                          isVarArgs:varargs];
        // Prefer a DIE that actually carries parameters over a bare declaration.
        XTDwarfFunction* prev = best[nm];
        if (!prev || (prev.paramTypes.count == 0 && ptypes.count > 0))
            best[nm] = fn;
        }
    return [best.allValues sortedArrayUsingComparator:^NSComparisonResult(XTDwarfFunction* a, XTDwarfFunction* b) {
      return [a.name compare:b.name];
    }];
    }

@end
