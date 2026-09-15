#import "XTMachOWriter.h"

// ── Mach-O constants (in-house so the writer needs no <mach-o/loader.h>) ──
enum
    {
    XMH_MAGIC_64 = 0xFEEDFACFu,
    XCPU_TYPE_ARM64 = 0x0100000Cu,
    XMH_EXECUTE = 2,
    XMH_DYLIB = 6,
    XMH_NOUNDEFS = 0x1,
    XMH_DYLDLINK = 0x4,
    XMH_TWOLEVEL = 0x80,
    XMH_PIE = 0x200000,
    };
enum
    {
    XLC_SYMTAB = 0x2,
    XLC_DYSYMTAB = 0xb,
    XLC_LOAD_DYLIB = 0xc,
    XLC_ID_DYLIB = 0xd,
    XLC_LOAD_DYLINKER = 0xe,
    XLC_SEGMENT_64 = 0x19,
    XLC_UUID = 0x1b,
    XLC_BUILD_VERSION = 0x32,
    XLC_MAIN = 0x28 | 0x80000000u,
    XLC_DYLD_INFO_ONLY = 0x22 | 0x80000000u,
    XLC_CODE_SIGNATURE = 0x1d,
    XLC_RPATH = 0x1c | 0x80000000u,
    };
enum
    {
    XVM_READ = 1,
    XVM_WRITE = 2,
    XVM_EXEC = 4
    };
// section types/attrs
enum
    {
    XS_REGULAR = 0,
    XS_NON_LAZY_SYMBOL_POINTERS = 6,
    // S_MOD_INIT_FUNC_POINTERS — an array of function pointers dyld CALLS
    // before the program's entry point. The section type is the whole
    // mechanism: the same bytes under XS_REGULAR are inert data (bug 066).
    XS_MOD_INIT_FUNC_POINTERS = 9,
    XS_ATTR_PURE_INSTRUCTIONS = 0x80000000u,
    XS_ATTR_SOME_INSTRUCTIONS = 0x400,
    };
// nlist
enum
    {
    XN_UNDF = 0x0,
    XN_SECT = 0xe,
    XN_EXT = 0x1,
    };
// bind opcodes
enum
    {
    BIND_DONE = 0x00,
    BIND_SET_DYLIB_ORDINAL_IMM = 0x10,
    // SPECIAL_IMM's low nibble is SIGN-extended: FLAT_LOOKUP is ordinal -2,
    // so the whole opcode byte is 0x30 | 0x0E. A dylib's own imports bind
    // this way (see dylibFromText) — its DEPENDENCIES are recorded on the
    // CLIENT, so at bind time dyld must search every loaded image rather
    // than an ordinal this image cannot name.
    BIND_SET_DYLIB_SPECIAL_FLAT = 0x3E,
    BIND_SET_SYMBOL_FLAGS = 0x40,
    BIND_SET_TYPE_IMM = 0x50,
    BIND_SET_ADDEND_SLEB = 0x60,
    BIND_SET_SEG_OFF_ULEB = 0x70,
    BIND_DO_BIND = 0x90,
    BIND_TYPE_POINTER = 1,
    };
// rebase opcodes
enum
    {
    REBASE_DONE = 0x00,
    REBASE_SET_TYPE_IMM = 0x10,
    REBASE_SET_SEG_OFF_ULEB = 0x20,
    REBASE_DO_IMM_TIMES = 0x50,
    REBASE_TYPE_POINTER = 1,
    };
#define PAGE 0x4000ull
#define VMBASE 0x100000000ull
#define STUB_SZ 12
#define GOT_SZ 8

static void put8(NSMutableData* d, uint8_t v)
    {
    [d appendBytes:&v length:1];
    }
static void put32(NSMutableData* d, uint32_t v)
    {
    uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
    [d appendBytes:b length:4];
    }
static void put64(NSMutableData* d, uint64_t v)
    {
    for (int i = 0; i < 8; i++)
        put8(d, (uint8_t)(v >> (8 * i)));
    }
static void putFixed(NSMutableData* d, const char* s, int n)
    {
    int len = (int)strlen(s);
    for (int i = 0; i < n; i++)
        put8(d, i < len ? (uint8_t)s[i] : 0);
    }
static void putULEB(NSMutableData* d, uint64_t v)
    {
    do
        {
        uint8_t b = v & 0x7f;
        v >>= 7;
        if (v)
            b |= 0x80;
        put8(d, b);
        } while (v);
    }
static void putSLEB(NSMutableData* d, int64_t v)
    {
    BOOL more = YES;
    while (more)
        {
        uint8_t b = v & 0x7F;
        v >>= 7;
        if ((v == 0 && !(b & 0x40)) || (v == -1 && (b & 0x40)))
            more = NO;
        else
            b |= 0x80;
        put8(d, b);
        }
    }
static uint64_t roundUp(uint64_t v, uint64_t a)
    {
    return (v + a - 1) & ~(a - 1);
    }
// big-endian appenders — code-signing blobs are big-endian
static void put32be(NSMutableData* d, uint32_t v)
    {
    uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    [d appendBytes:b length:4];
    }
static void put64be(NSMutableData* d, uint64_t v)
    {
    for (int i = 7; i >= 0; i--)
        put8(d, (uint8_t)(v >> (8 * i)));
    }

// ── SHA-256 (self-contained; the ad-hoc code signature hashes each 4 KiB page) ──
typedef struct
    {
    uint32_t s[8];
    uint64_t len;
    uint8_t buf[64];
    uint32_t n;
    } SHA256;
static uint32_t ror32(uint32_t x, int r)
    {
    return (x >> r) | (x << (32 - r));
    }
static void sha256_block(SHA256* c, const uint8_t* p)
    {
    static const uint32_t K[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = (p[i * 4] << 24) | (p[i * 4 + 1] << 16) | (p[i * 4 + 2] << 8) | p[i * 4 + 3];
    for (int i = 16; i < 64; i++)
        {
        uint32_t s0 = ror32(w[i - 15], 7) ^ ror32(w[i - 15], 18) ^ (w[i - 15] >> 3),
                 s1 = ror32(w[i - 2], 17) ^ ror32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
    uint32_t a = c->s[0], b = c->s[1], cc = c->s[2], d = c->s[3], e = c->s[4], f = c->s[5], g = c->s[6], h = c->s[7];
    for (int i = 0; i < 64; i++)
        {
        uint32_t S1 = ror32(e, 6) ^ ror32(e, 11) ^ ror32(e, 25), ch = (e & f) ^ (~e & g), t1 = h + S1 + ch + K[i] + w[i],
                 S0 = ror32(a, 2) ^ ror32(a, 13) ^ ror32(a, 22), maj = (a & b) ^ (a & cc) ^ (b & cc), t2 = S0 + maj;
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = cc;
        cc = b;
        b = a;
        a = t1 + t2;
        }
    c->s[0] += a;
    c->s[1] += b;
    c->s[2] += cc;
    c->s[3] += d;
    c->s[4] += e;
    c->s[5] += f;
    c->s[6] += g;
    c->s[7] += h;
    }
static void sha256_init(SHA256* c)
    {
    static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(c->s, iv, sizeof iv);
    c->len = 0;
    c->n = 0;
    }
static void sha256_update(SHA256* c, const uint8_t* p, size_t n)
    {
    c->len += n;
    while (n)
        {
        size_t k = 64 - c->n;
        if (k > n)
            k = n;
        memcpy(c->buf + c->n, p, k);
        c->n += k;
        p += k;
        n -= k;
        if (c->n == 64)
            {
            sha256_block(c, c->buf);
            c->n = 0;
            }
        }
    }
static void sha256_final(SHA256* c, uint8_t out[32])
    {
    uint64_t bits = c->len * 8;
    uint8_t pad = 0x80;
    sha256_update(c, &pad, 1);
    uint8_t z = 0;
    while (c->n != 56)
        sha256_update(c, &z, 1);
    uint8_t lb[8];
    for (int i = 0; i < 8; i++)
        lb[i] = (uint8_t)(bits >> (56 - 8 * i));
    sha256_update(c, lb, 8);
    for (int i = 0; i < 8; i++)
        {
        out[i * 4] = (uint8_t)(c->s[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(c->s[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(c->s[i] >> 8);
        out[i * 4 + 3] = (uint8_t)c->s[i];
        }
    }

// Build an ad-hoc embedded code signature (SuperBlob{CodeDirectory}) over the
// first `codeLimit` bytes of `file`, hashing each 4 KiB page. `ident` is the
// signing identifier (the binary's name). CodeDirectory version 0x20400 with the
// execSeg fields — what current dyld/AMFI expect for a main executable.
static NSData* buildAdhocSignature(const uint8_t* file, uint64_t codeLimit,
                                   NSString* ident, uint64_t execSegLimit)
    {
    const uint32_t CS_PAGE = 4096;
    const char* id = ident.UTF8String;
    uint32_t idLen = (uint32_t)strlen(id);
    uint32_t nCodeSlots = (uint32_t)((codeLimit + CS_PAGE - 1) / CS_PAGE);
    uint32_t hdr = 88; // v0x20400 header size
    uint32_t identOffset = hdr;
    uint32_t hashOffset = identOffset + idLen + 1; // 0 special slots
    uint32_t cdLength = hashOffset + nCodeSlots * 32;

    NSMutableData* cd = [NSMutableData data];
    put32be(cd, 0xfade0c02); // CSMAGIC_CODEDIRECTORY
    put32be(cd, cdLength);
    put32be(cd, 0x20400); // length, version
    put32be(cd, 0x2);     // flags: adhoc
    put32be(cd, hashOffset);
    put32be(cd, identOffset);
    put32be(cd, 0);
    put32be(cd, nCodeSlots); // nSpecialSlots, nCodeSlots
    put32be(cd, (uint32_t)codeLimit);
    put8(cd, 32);
    put8(cd, 2);
    put8(cd, 0);
    put8(cd, 12);   // hashSize, hashType=SHA256, platform, pageSize=log2(4096)
    put32be(cd, 0); // spare2
    put32be(cd, 0); // scatterOffset (>=0x20100)
    put32be(cd, 0); // teamOffset (>=0x20200)
    put32be(cd, 0);
    put64be(cd, 0); // spare3, codeLimit64 (>=0x20300)
    put64be(cd, 0);
    put64be(cd, execSegLimit);
    put64be(cd, 0x1);                     // execSegBase, Limit, Flags=MAIN_BINARY (>=0x20400)
    [cd appendBytes:id length:idLen + 1]; // identifier
    // one SHA-256 per page
    for (uint32_t i = 0; i < nCodeSlots; i++)
        {
        uint64_t off = (uint64_t)i * CS_PAGE, len = codeLimit - off;
        if (len > CS_PAGE)
            len = CS_PAGE;
        SHA256 c;
        sha256_init(&c);
        sha256_update(&c, file + off, (size_t)len);
        uint8_t h[32];
        sha256_final(&c, h);
        [cd appendBytes:h length:32];
        }
    NSMutableData* sb = [NSMutableData data]; // SuperBlob{ CodeDirectory }
    put32be(sb, 0xfade0cc0);                  // CSMAGIC_EMBEDDED_SIGNATURE
    put32be(sb, 12 + 8 + cdLength);
    put32be(sb, 1); // length, count
    put32be(sb, 0);
    put32be(sb, 20); // slot type=CodeDirectory, offset
    [sb appendData:cd];
    return sb;
    }

// arm64 stub: adrp x16,slotpage ; ldr x16,[x16,#slotoff] ; br x16
static void emitStub(NSMutableData* code, uint64_t stubAddr, uint64_t slotAddr)
    {
    int64_t pd = (int64_t)((slotAddr & ~0xFFFull) - (stubAddr & ~0xFFFull));
    int64_t imm = pd >> 12;
    uint32_t immlo = (uint32_t)(imm & 3), immhi = (uint32_t)((imm >> 2) & 0x7FFFF);
    uint32_t adrp = 0x90000010u | (immlo << 29) | (immhi << 5);                // Rd=16
    uint32_t ldr = 0xF9400210u | (((uint32_t)((slotAddr & 0xFFF) / 8)) << 10); // x16,[x16,#off]
    uint32_t br = 0xD61F0200u;                                                 // br x16
    put32(code, adrp);
    put32(code, ldr);
    put32(code, br);
    }

static uint32_t ulebLen(uint64_t v)
    {
    uint32_t n = 1;
    while (v >= 0x80)
        {
        v >>= 7;
        n++;
        }
    return n;
    }

// Export trie — a real prefix tree, which is what the format is.
//
// dyld consults THIS, not the classic N_EXT symtab, to resolve a two-level
// import against a dylib. Each node is:
//
//     ULEB terminalSize [ u8 flags, ULEB address ]  u8 childCount
//     { cstring edge, ULEB offset-of-child } * childCount
//
// This used to build a DEGENERATE trie: one root whose children were the whole
// symbol names. `childCount` is a single byte, so that capped an image at 255
// exports — and past it the writer truncated and logged a warning. The library
// then linked, type-checked, and failed in the dynamic loader at the user's
// run time, naming a symbol the compiler had silently dropped. Which symbols
// survived depended on emission order, so it looked arbitrary (private:docs/bugs/042).
//
// The limit is per NODE, not per image. Partitioning by one character at a time
// bounds childCount by the number of distinct next characters — at most 255 for
// any byte alphabet, and well under that for C identifiers — so a real trie has
// no cap worth naming. Chains are compressed as they are built (an edge carries
// the whole common prefix), which is what keeps the trie small rather than one
// node per character.

@interface XTExportTrieNode : NSObject
@property(nonatomic) BOOL terminal;
@property(nonatomic) uint64_t addr;
@property(nonatomic, strong) NSMutableArray<NSString*>* edges;
@property(nonatomic, strong) NSMutableArray<XTExportTrieNode*>* kids;
@property(nonatomic) uint32_t offset; // trie-relative, solved by fixpoint
@property(nonatomic) uint32_t size;
@end

@implementation XTExportTrieNode
- (instancetype)init
    {
    if ((self = [super init]))
        {
        _edges = [NSMutableArray array];
        _kids = [NSMutableArray array];
        }
    return self;
    }
@end

// Build the sub-trie for `idxs`, all of which share the first `depth` bytes.
static XTExportTrieNode* trieBuild(NSArray<NSString*>* names, NSArray<NSNumber*>* addrs,
                                   NSArray<NSNumber*>* idxs, NSUInteger depth)
    {
    XTExportTrieNode* node = [[XTExportTrieNode alloc] init];
    NSMutableArray<NSNumber*>* rest = [NSMutableArray array];
    for (NSNumber* ix in idxs)
        {
        NSString* nm = names[ix.unsignedIntegerValue];
        // this name ENDS here — the node exports it
        if (strlen(nm.UTF8String) == depth)
            {
            node.terminal = YES;
            node.addr = addrs[ix.unsignedIntegerValue].unsignedLongLongValue;
            }
        else
            {
            [rest addObject:ix];
            }
        }
    // Partition what is left by the next byte, preserving first-seen order so
    // the output is a function of the input and not of a hash.
    NSMutableArray<NSNumber*>* order = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, NSMutableArray<NSNumber*>*>* groups = [NSMutableDictionary dictionary];
    for (NSNumber* ix in rest)
        {
        const char* c = names[ix.unsignedIntegerValue].UTF8String;
        NSNumber* key = @((uint8_t)c[depth]);
        if (!groups[key])
            {
            groups[key] = [NSMutableArray array];
            [order addObject:key];
            }
        [groups[key] addObject:ix];
        }
    for (NSNumber* key in order)
        {
        NSMutableArray<NSNumber*>* g = groups[key];
        // Longest common prefix of the group beyond `depth` — that whole run
        // becomes ONE edge, so a chain of single-child nodes never appears.
        const char* first = names[g[0].unsignedIntegerValue].UTF8String;
        NSUInteger firstLen = strlen(first);
        NSUInteger lcp = depth + 1;
        while (lcp < firstLen)
            {
            BOOL all = YES;
            for (NSNumber* ix in g)
                {
                const char* c = names[ix.unsignedIntegerValue].UTF8String;
                if (strlen(c) <= lcp || c[lcp] != first[lcp])
                    {
                    all = NO;
                    break;
                    }
                }
            if (!all)
                break;
            lcp++;
            }
        NSString* edge = [[NSString alloc] initWithBytes:first + depth
                                                  length:lcp - depth
                                                encoding:NSUTF8StringEncoding];
        if (!edge)
            edge = @"";
        [node.edges addObject:edge];
        [node.kids addObject:trieBuild(names, addrs, g, lcp)];
        }
    return node;
    }

static void trieFlatten(XTExportTrieNode* n, NSMutableArray<XTExportTrieNode*>* out)
    {
    [out addObject:n];
    for (XTExportTrieNode* k in n.kids)
        trieFlatten(k, out);
    }

static uint32_t trieNodeSize(XTExportTrieNode* n)
    {
    uint32_t sz = 0;
    if (n.terminal)
        {
        uint32_t term = 1 /*flags*/ + ulebLen(n.addr);
        sz += ulebLen(term) + term;
        }
    else
        {
        sz += 1; // terminalSize = 0
        }
    sz += 1; // childCount
    for (NSUInteger i = 0; i < n.kids.count; i++)
        {
        sz += (uint32_t)(strlen(n.edges[i].UTF8String) + 1);
        sz += ulebLen(n.kids[i].offset); // ULEB width depends on the offset
        }
    return sz;
    }

static NSData* buildExportTrie(NSArray<NSString*>* names, NSArray<NSNumber*>* addrs)
    {
    NSUInteger n = names.count;
    if (n == 0)
        return [NSData data];
    NSMutableArray<NSNumber*>* all = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++)
        [all addObject:@(i)];
    XTExportTrieNode* root = trieBuild(names, addrs, all, 0);

    NSMutableArray<XTExportTrieNode*>* nodes = [NSMutableArray array];
    trieFlatten(root, nodes);

    // A node's size depends on its children's offsets, and their offsets depend
    // on the sizes ahead of them — so solve it. Sizes only ever grow as offsets
    // grow, so this converges; the loop is capped and the result is checked.
    BOOL settled = NO;
    for (int iter = 0; iter < 16 && !settled; iter++)
        {
        uint32_t off = 0;
        for (XTExportTrieNode* nd in nodes)
            {
            nd.offset = off;
            off += trieNodeSize(nd);
            }
        settled = YES;
        uint32_t chk = 0;
        for (XTExportTrieNode* nd in nodes)
            {
            if (nd.offset != chk)
                {
                settled = NO;
                break;
                }
            chk += trieNodeSize(nd);
            }
        }
    for (XTExportTrieNode* nd in nodes)
        nd.size = trieNodeSize(nd);

    NSMutableData* trie = [NSMutableData data];
    for (XTExportTrieNode* nd in nodes)
        {
        NSCAssert(trie.length == nd.offset, @"export trie layout did not settle");
        if (nd.terminal)
            {
            uint32_t term = 1 + ulebLen(nd.addr);
            putULEB(trie, term);
            put8(trie, 0); // flags = REGULAR
            putULEB(trie, nd.addr);
            }
        else
            {
            put8(trie, 0); // terminalSize = 0
            }
        // Guaranteed by construction — one byte of alphabet per level — but a
        // silently truncated trie is exactly what 042 was, so it is checked.
        if (nd.kids.count > 255)
            {
            NSLog(@"xcc: internal error: export trie node has %lu children",
                  (unsigned long)nd.kids.count);
            return [NSData data];
            }
        put8(trie, (uint8_t)nd.kids.count);
        for (NSUInteger i = 0; i < nd.kids.count; i++)
            {
            const char* c = nd.edges[i].UTF8String;
            [trie appendBytes:c length:strlen(c) + 1];
            putULEB(trie, nd.kids[i].offset);
            }
        }
    return trie;
    }

// LC_BUILD_VERSION platform stamp — see +setApplePlatform: in the header.
static uint32_t sPlatformId = 1;           // PLATFORM_MACOS
static uint32_t sPlatformMinos = 11 << 16; // 11.0
static uint32_t sPlatformSdk = 11 << 16;

@implementation XTMachOWriter

// The `.tbd` target triples this platform's exports are listed under. A `.tbd`
// carries several platforms in one file and tags each `symbols:` list with the
// targets it applies to, so reading the wrong ones yields NO symbols rather
// than wrong ones — see sTbdTargets' use in inspectTbd (private:docs/bugs/028).
static NSArray<NSString*>* sTbdTargets = nil;

+ (void)setApplePlatform:(nullable NSString*)platform
    {
    if (platform == nil || [platform isEqualToString:@"macos"])
        {
        sPlatformId = 1;
        sPlatformMinos = 11 << 16;
        sPlatformSdk = 11 << 16;
        sTbdTargets = @[ @"arm64-macos", @"arm64e-macos" ];
        }
    else if ([platform isEqualToString:@"ios"])
        {
        sPlatformId = 2;
        sPlatformMinos = 15 << 16;
        sPlatformSdk = 15 << 16;
        sTbdTargets = @[ @"arm64-ios", @"arm64e-ios" ];
        }
    else if ([platform isEqualToString:@"ios-sim"])
        {
        sPlatformId = 7;
        sPlatformMinos = 15 << 16;
        sPlatformSdk = 15 << 16;
        sTbdTargets = @[ @"arm64-ios-simulator", @"arm64e-ios-simulator" ];
        }
    }

+ (NSArray<NSString*>*)tbdTargets
    {
    return sTbdTargets ?: @[ @"arm64-macos", @"arm64e-macos" ];
    }

+ (NSData*)executableFromText:(NSData*)textIn
                  entryOffset:(uint64_t)entryOffset
                      symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                         data:(NSData*)dataIn
                  dataSymbols:(NSSet<NSString*>*)dataSymbols
                       fixups:(NSArray<XAArm64Fixup*>*)fixups
    {
    // No mod-init section: this convenience form is for images that have no
    // load-time constructors to describe (bug 066).
    return [self executableFromText:textIn
                        entryOffset:entryOffset
                            symbols:symbols
                               data:dataIn
                        dataSymbols:dataSymbols
                             fixups:fixups
                             dylibs:@[]
                             rpaths:@[]
                      modInitLength:0
                       objcSections:@[]];
    }

// Parse a dylib: install name (LC_ID_DYLIB) + exported symbol names (the
// external-defined range of LC_SYMTAB, per LC_DYSYMTAB). arm64 little-endian
// Mach-O only — which is all this toolchain produces or consumes.
+ (NSDictionary*)inspectDylib:(NSString*)path
    {
    NSData* d = [NSData dataWithContentsOfFile:path];
    if (d.length < 32)
        return nil;
    const uint8_t* b = d.bytes;
    uint32_t (^rd)(uint64_t) = ^uint32_t(uint64_t o) {
      return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | ((uint32_t)b[o + 3] << 24);
    };
    if (rd(0) != XMH_MAGIC_64)
        return nil;
    uint32_t ncmds = rd(16);
    uint64_t off = 32;
    NSString* install = nil;
    uint32_t symoff = 0, nsyms = 0, stroff = 0, iextdef = 0, nextdef = 0;
    BOOL haveDysym = NO;
    for (uint32_t i = 0; i < ncmds && off + 8 <= d.length; i++)
        {
        uint32_t cmd = rd(off), csz = rd(off + 4);
        if (cmd == XLC_ID_DYLIB)
            {
            uint32_t noff = rd(off + 8);
            if (off + noff < d.length)
                install = [NSString stringWithUTF8String:(const char*)(b + off + noff)];
            }
        else if (cmd == XLC_SYMTAB)
            {
            symoff = rd(off + 8);
            nsyms = rd(off + 12);
            stroff = rd(off + 16);
            }
        else if (cmd == XLC_DYSYMTAB)
            {
            iextdef = rd(off + 8 + 8);
            nextdef = rd(off + 8 + 12);
            haveDysym = YES;
            }
        off += csz;
        }
    NSMutableSet<NSString*>* syms = [NSMutableSet set];
    if (symoff && stroff)
        {
        // If DYSYMTAB gave an external-defined range, use it; else scan all N_EXT|N_SECT.
        uint32_t lo = haveDysym ? iextdef : 0, hi = haveDysym ? iextdef + nextdef : nsyms;
        for (uint32_t i = lo; i < hi && symoff + (uint64_t)(i + 1) * 16 <= d.length; i++)
            {
            uint64_t e = symoff + (uint64_t)i * 16;
            uint32_t strx = rd(e);
            uint8_t type = b[e + 4];
            if (!haveDysym && !((type & XN_EXT) && (type & 0xe) == XN_SECT))
                continue;
            if (stroff + strx < d.length)
                {
                NSString* nm = [NSString stringWithUTF8String:(const char*)(b + stroff + strx)];
                if (nm.length)
                    [syms addObject:nm];
                }
            }
        }
    return @{@"install" : install ?: path.lastPathComponent, @"symbols" : syms};
    }

// Parse a TBD v4 text stub. We need only the library's `install-name` and the
// exported symbol names available on our target (arm64-macos). The format is
// regular YAML: an `install-name:` scalar, then `exports:`/`reexports:` entries
// each pairing a `targets: [ … ]` list with a `symbols: [ … ]` list (either may
// wrap across lines). We track the most-recent `targets:` block and, when it
// includes arm64(-|e-)macos, collect the following `symbols:`. Over-parsing a
// reexport's symbols is harmless (dyld resolves the reexport chain), and a symbol
// the program never references is simply ignored by the binder.
// Parsed `.tbd` results, keyed by path AND platform (the targets decide which
// symbols apply, so one file has different answers per platform).
//
// A cache rather than a nicety: following re-exports multiplies the work —
// Foundation alone pulls in CoreFoundation and libobjc — and the files are
// large (Foundation.tbd is 6.8 MB). Reading each one once per link is the
// difference between a usable edit-run loop and the minutes uxkit/027 measured.
static NSMutableDictionary<NSString*, NSDictionary*>* sTbdCache = nil;

+ (nullable NSDictionary*)inspectTbd:(NSString*)path
    {
    if (!sTbdCache)
        sTbdCache = [NSMutableDictionary dictionary];
    NSString* key = [NSString stringWithFormat:@"%@|%u", path, sPlatformId];
    NSDictionary* hit = sTbdCache[key];
    if (hit)
        return (hit.count ? hit : nil);
    NSDictionary* r = [self inspectTbdUncached:path depth:0];
    sTbdCache[key] = r ?: @{};
    return r;
    }

// `depth` bounds the re-export walk; the chains are short (Foundation →
// CoreFoundation → …) but a cycle must not be fatal.
+ (nullable NSDictionary*)inspectTbdUncached:(NSString*)path depth:(int)depth
    {
    NSString* txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (!txt || ![txt containsString:@"tapi-tbd"])
        return nil;
    NSArray<NSString*>* lines = [txt componentsSeparatedByString:@"\n"];
    NSCharacterSet* ws = [NSCharacterSet whitespaceCharacterSet];
    NSCharacterSet* quo = [NSCharacterSet characterSetWithCharactersInString:@" '\""];
    NSString* install = nil;
    NSMutableSet<NSString*>* syms = [NSMutableSet set];
    NSMutableArray<NSString*>* reexports = [NSMutableArray array];
    BOOL curArm64 = NO;
    BOOL inReexports = NO;
    for (NSUInteger i = 0; i < lines.count; i++)
        {
        NSString* t = [lines[i] stringByTrimmingCharactersInSet:ws];
        if (!install && [t hasPrefix:@"install-name:"])
            {
            install = [[t substringFromIndex:13] stringByTrimmingCharactersInSet:quo];
            continue;
            }
        // A `.tbd` names its re-exported libraries before its own exports. A
        // symbol reached through one of them is provided BY THIS dylib as far
        // as binding is concerned — dyld resolves it through this ordinal — so
        // those libraries' exports are unioned in below. Without it,
        // Foundation's `_NSRunLoopCommonModes` (which actually lives in
        // CoreFoundation) is in no export set at all and every DATA bind that
        // needs it falls back to ordinal 1. uxkit/028 addendum.
        if ([t hasPrefix:@"reexported-libraries:"])
            {
            inReexports = YES;
            continue;
            }
        if ([t hasPrefix:@"exports:"] || [t hasPrefix:@"symbols:"] || [t hasPrefix:@"objc-classes:"])
            inReexports = NO;

        NSString* key = nil;
        if ([t hasPrefix:@"- targets:"])
            key = @"- targets:";
        else if ([t hasPrefix:@"targets:"])
            key = @"targets:";
        else if ([t hasPrefix:@"symbols:"])
            key = @"symbols:";
        else if ([t hasPrefix:@"- symbols:"])
            key = @"- symbols:";
        // A `.tbd` lists Objective-C classes SEPARATELY from `symbols:`, by
        // bare class name — the linker-visible `_OBJC_CLASS_$_<name>` and
        // `_OBJC_METACLASS_$_<name>` appear nowhere in the file. Reading only
        // `symbols:` therefore missed every ObjC class a framework vends, so a
        // reference to `_OBJC_CLASS_$_NSApplication` fell through to dylib
        // ordinal 1 exactly as bug 028's plain data symbols did. `objc-eh-types:`
        // is the same shape for `_OBJC_EHTYPE_$_<name>`.
        else if ([t hasPrefix:@"objc-classes:"])
            key = @"objc-classes:";
        else if ([t hasPrefix:@"- objc-classes:"])
            key = @"- objc-classes:";
        else if ([t hasPrefix:@"objc-eh-types:"])
            key = @"objc-eh-types:";
        else if ([t hasPrefix:@"- objc-eh-types:"])
            key = @"- objc-eh-types:";
        else if (inReexports && [t hasPrefix:@"libraries:"])
            key = @"libraries:";
        else if (inReexports && [t hasPrefix:@"- libraries:"])
            key = @"- libraries:";
        if (!key)
            continue;
        // Accumulate the bracketed list, which may wrap over several lines.
        //
        // The termination test looks at the LINE just appended, not at the
        // whole buffer. Re-scanning the buffer each time is quadratic, and a
        // `symbols:` list here is not small: Foundation.tbd holds ~52 000
        // symbols across thousands of wrapped lines, and rescanning a
        // megabytes-long accumulator per line cost 7m42s to read that one file
        // — most of uxkit/027's "78s for one framework, ~9min for three".
        NSMutableString* buf = [[t substringFromIndex:key.length] mutableCopy];
        BOOL closed = [buf containsString:@"]"];
        while (!closed && i + 1 < lines.count)
            {
            i++;
            [buf appendString:@" "];
            [buf appendString:lines[i]];
            closed = [lines[i] containsString:@"]"];
            }
        NSRange lb = [buf rangeOfString:@"["];
        NSRange rb = [buf rangeOfString:@"]" options:NSBackwardsSearch];
        if (lb.location == NSNotFound || rb.location == NSNotFound || rb.location <= lb.location)
            continue;
        NSString* inner = [buf substringWithRange:NSMakeRange(lb.location + 1, rb.location - lb.location - 1)];
        NSArray<NSString*>* items = [inner componentsSeparatedByString:@","];
        if ([key hasSuffix:@"targets:"])
            {
            // Match the target triples for the platform being LINKED, not
            // macOS's. A `.tbd` tags each symbols: list with its targets, so
            // reading the wrong ones collects NOTHING — and an empty export set
            // is silent: the symbol still resolves, it just falls through to
            // dylib ordinal 1 (libSystem) and dyld refuses at launch naming a
            // library that never had it. private:docs/bugs/028.
            curArm64 = NO;
            NSArray<NSString*>* want = [XTMachOWriter tbdTargets];
            for (NSString* it in items)
                {
                NSString* s = [it stringByTrimmingCharactersInSet:ws];
                if ([want containsObject:s])
                    {
                    curArm64 = YES;
                    break;
                    }
                }
            }
        else if ([key hasSuffix:@"libraries:"])
            {
            if (!curArm64)
                continue;
            for (NSString* it in items)
                {
                NSString* s = [it stringByTrimmingCharactersInSet:quo];
                if (s.length)
                    [reexports addObject:s];
                }
            }
        else if ([key hasSuffix:@"objc-classes:"])
            {
            if (!curArm64)
                continue;
            for (NSString* it in items)
                {
                NSString* s = [it stringByTrimmingCharactersInSet:quo];
                if (!s.length)
                    continue;
                [syms addObject:[@"_OBJC_CLASS_$_" stringByAppendingString:s]];
                [syms addObject:[@"_OBJC_METACLASS_$_" stringByAppendingString:s]];
                }
            }
        else if ([key hasSuffix:@"objc-eh-types:"])
            {
            if (!curArm64)
                continue;
            for (NSString* it in items)
                {
                NSString* s = [it stringByTrimmingCharactersInSet:quo];
                if (s.length)
                    [syms addObject:[@"_OBJC_EHTYPE_$_" stringByAppendingString:s]];
                }
            }
        // a symbols: list for our target
        else if (curArm64)
            {
            for (NSString* it in items)
                {
                NSString* s = [it stringByTrimmingCharactersInSet:quo];
                if (s.length)
                    [syms addObject:s];
                }
            }
        }
    if (!install)
        return nil;

    // Pull in what this dylib RE-EXPORTS. The .tbd for a re-exported library
    // sits at the same place inside the SDK its install-name describes, so the
    // SDK root is recovered by stripping this file's own install-name (plus
    // `.tbd`) off the end of its path — no SDK-location guessing.
    if (depth < 4 && reexports.count)
        {
        NSString* suffix = [install stringByAppendingString:@".tbd"];
        // Resolve SYMLINKS first. `-framework Cocoa` finds
        // `Cocoa.framework/Cocoa.tbd`, which is a symlink to
        // `Versions/Current/Cocoa.tbd`; only the RESOLVED path ends with the
        // install-name (`…/Versions/A/Cocoa`). Testing the given path silently
        // recovered no SDK root, so no re-export was followed and every symbol
        // an umbrella provides fell back to libSystem — 265 of them in one
        // AppKit link, `_NSApp` and `_NSEventTrackingRunLoopMode` among them.
        // Umbrellas are exactly the frameworks reached by that symlink, so this
        // failed precisely where re-export walking is the whole point.
        NSString* real = [path stringByResolvingSymlinksInPath] ?: path;
        NSString* sdkRoot = [real hasSuffix:suffix]
                                ? [real substringToIndex:real.length - suffix.length]
                                : ([path hasSuffix:suffix]
                                       ? [path substringToIndex:path.length - suffix.length]
                                       : nil);
        if (sdkRoot)
            {
            for (NSString* lib in reexports)
                {
                NSString* sub = [[sdkRoot stringByAppendingString:lib]
                    stringByAppendingString:@".tbd"];
                if (![[NSFileManager defaultManager] fileExistsAtPath:sub])
                    continue;
                NSDictionary* r = [self inspectTbdUncached:sub depth:depth + 1];
                if (r[@"symbols"])
                    [syms unionSet:r[@"symbols"]];
                }
            }
        }
    return @{@"install" : install, @"symbols" : syms};
    }

// Parse a static `ar` archive of arm64 MH_OBJECT members. Returns one dict per
// object member: @{@"text": <__text bytes NSData>, @"symbols": @{name→NSNumber
// offset-in-text}, @"relocs": @[ @{@"off","sym","type","pcrel","len"} ]}. The
// caller pulls members that define a referenced symbol, appends their __text, and
// applies the relocations. Handles the BSD `#1/<len>` long-name form and skips the
// `__.SYMDEF` ranlib index. nil if the file isn't a parseable archive.

// ── MH_OBJECT: the write direction ────────────────────────────────────────
//
// The executable path RESOLVES the assembler's fixups (binding each to an
// address or an import stub). An object does the opposite: it keeps the text
// verbatim and records every fixup as a relocation, leaving the binding to
// whoever links it. Everything else — the section layout, the symbol table — is
// the same furniture in a smaller room.
//
// Layout: header | LC_SEGMENT_64(__text,__data) | LC_SYMTAB | LC_DYSYMTAB
//         then text, data, text relocs, data relocs, nlist_64[], strings.
// LC_DYSYMTAB is not needed by our own reader (+parseObject: reads LC_SYMTAB
// alone) but Apple's ld wants one, and being linkable by the system linker is
// the external check that this file is really an object rather than something
// only we can read.
+ (NSData*)objectFromText:(NSData*)text
                  symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                     data:(nullable NSData*)dataIn
              dataSymbols:(nullable NSSet<NSString*>*)dataSymbols
                   fixups:(NSArray<XAArm64Fixup*>*)fixups
                  exports:(nullable NSSet<NSString*>*)exports
                  commons:(nullable NSDictionary<NSString*, NSArray<NSNumber*>*>*)commons
    {
    NSData* data = dataIn ?: [NSData data];
    NSSet* dsyms = dataSymbols ?: [NSSet set];
    NSDictionary<NSString*, NSArray<NSNumber*>*>* comms = commons ?: @{};

    // ── symbol table: defined text, defined data, then undefined ──────────
    // Sorted within each group so the file is reproducible — two builds of the
    // same input must not differ because a dictionary enumerated differently.
    // Symbol table order is [locals][externs][undefs], which LC_DYSYMTAB
    // requires. `exports` (the assembler's `.globl` set) decides which defined
    // symbol is external; nil keeps the old everything-external behaviour. A
    // local is private to its object: the linker tags it per object, so two
    // objects' `_str_N` literals no longer collide (bug 136).
    NSMutableArray<NSString*>* defText = [NSMutableArray array];
    NSMutableArray<NSString*>* defData = [NSMutableArray array];
    NSMutableArray<NSString*>* locText = [NSMutableArray array];
    NSMutableArray<NSString*>* locData = [NSMutableArray array];
    for (NSString* n in [symbols.allKeys sortedArrayUsingSelector:@selector(compare:)])
        {
        if ([n hasPrefix:@"L"])
            continue; // assembler-local, already resolved
        BOOL ext = (exports == nil) || [exports containsObject:n];
        NSMutableArray* dst = ext ? ([dsyms containsObject:n] ? defData : defText)
                                  : ([dsyms containsObject:n] ? locData : locText);
        [dst addObject:n];
        }
    NSUInteger nLocals = locText.count + locData.count;
    NSMutableSet<NSString*>* undefSet = [NSMutableSet set];
    for (XAArm64Fixup* f in fixups)
        if (f.symbol && !symbols[f.symbol])
            [undefSet addObject:f.symbol];
    // COMMON (`.comm`) symbols are external undefined-with-size — they sit with
    // the undefined externals whether or not this object references them, so the
    // linker sees the size and gives one shared slot (bug 169).
    for (NSString* cn in comms)
        [undefSet addObject:cn];
    NSArray<NSString*>* undef =
        [undefSet.allObjects sortedArrayUsingSelector:@selector(compare:)];

    NSMutableArray<NSString*>* order = [NSMutableArray array];
    [order addObjectsFromArray:locText];
    [order addObjectsFromArray:locData];
    [order addObjectsFromArray:defText];
    [order addObjectsFromArray:defData];
    [order addObjectsFromArray:undef];
    NSMutableDictionary<NSString*, NSNumber*>* symIndex = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < order.count; i++)
        symIndex[order[i]] = @(i);

    // ── relocations, split by the section the fixup lives in ──────────────
    // A Pointer64 fixup patches a `.quad sym` inside __data; every other kind
    // patches an instruction in __text.
    NSMutableData *textRel = [NSMutableData data], *dataRel = [NSMutableData data];
    uint32_t nTextRel = 0, nDataRel = 0;
    for (XAArm64Fixup* f in fixups)
        {
        NSNumber* si = symIndex[f.symbol];
        if (!si)
            continue; // nothing names it; nothing to bind
        uint32_t type, pcrel, length;
        switch (f.kind)
            {
        case XAArm64FixupBranch26:
            type = 2;
            pcrel = 1;
            length = 2;
            break;
        case XAArm64FixupPage21:
            type = 3;
            pcrel = 1;
            length = 2;
            break;
        case XAArm64FixupPageOff12:
            type = 4;
            pcrel = 0;
            length = 2;
            break;
        case XAArm64FixupGotPage21:
            type = 5;
            pcrel = 1;
            length = 2;
            break;
        case XAArm64FixupGotPageOff12:
            type = 6;
            pcrel = 0;
            length = 2;
            break;
        case XAArm64FixupPointer64:
            type = 0;
            pcrel = 0;
            length = 3;
            break;
        default:
            continue;
            }
        BOOL inData = (f.kind == XAArm64FixupPointer64);
        NSMutableData* into = inData ? dataRel : textRel;
        // An ARM64_RELOC_ADDEND must PRECEDE the pair it applies to; its
        // "symbolnum" field carries the addend value, not a symbol index.
        if (f.addend && !inData)
            {
            put32(into, (uint32_t)f.offset);
            put32(into, (uint32_t)((10u << 28) | (1u << 27) | (2u << 25) | ((uint32_t)f.addend & 0xFFFFFFu)));
            nTextRel++;
            }
        put32(into, (uint32_t)f.offset);
        put32(into, (uint32_t)((type << 28) | (1u << 27) | (length << 25) | (pcrel << 24) | ((uint32_t)si.unsignedIntValue & 0xFFFFFFu)));
        if (inData)
            nDataRel++;
        else
            nTextRel++;
        }

    // ── file offsets ──────────────────────────────────────────────────────
    // LC_BUILD_VERSION: without it `ld` warns "no platform load command found,
    // assuming: macOS". It is assuming correctly, but a real object says so.
    const uint32_t hdrSize = 32, segCmd = 72 + 80 * 2, symCmd = 24, dysymCmd = 80;
    const uint32_t buildCmd = 24;
    uint32_t sizeofcmds = segCmd + symCmd + dysymCmd + buildCmd;
    uint64_t textOff = hdrSize + sizeofcmds;
    textOff = (textOff + 15) & ~15ull;
    uint64_t dataOff = textOff + text.length;
    dataOff = (dataOff + 15) & ~15ull;
    uint64_t textRelOff = dataOff + data.length;
    uint64_t dataRelOff = textRelOff + textRel.length;
    uint64_t symOff = dataRelOff + dataRel.length;
    symOff = (symOff + 7) & ~7ull;
    uint64_t strOff = symOff + order.count * 16;

    NSMutableData* strtab = [NSMutableData data];
    put8(strtab, 0); // index 0 is the empty string
    NSMutableArray<NSNumber*>* strx = [NSMutableArray array];
    for (NSString* n in order)
        {
        [strx addObject:@(strtab.length)];
        const char* c = [n UTF8String];
        [strtab appendBytes:c length:strlen(c) + 1];
        }
    while (strtab.length & 7)
        put8(strtab, 0);

    NSMutableData* out = [NSMutableData data];
    put32(out, 0xFEEDFACF);
    put32(out, XCPU_TYPE_ARM64);
    put32(out, 0);
    put32(out, 1 /*MH_OBJECT*/);
    put32(out, 4 /*ncmds*/);
    put32(out, sizeofcmds);
    put32(out, 0 /*flags*/);
    put32(out, 0);

    // One unnamed segment holding both sections — the MH_OBJECT convention.
    put32(out, XLC_SEGMENT_64);
    put32(out, segCmd);
    putFixed(out, "", 16);
    put64(out, 0);
    put64(out, text.length + data.length);
    put64(out, textOff);
    put64(out, text.length + data.length);
    put32(out, 7);
    put32(out, 7);
    put32(out, 2 /*nsects*/);
    put32(out, 0);

    putFixed(out, "__text", 16);
    putFixed(out, "__TEXT", 16);
    put64(out, 0);
    put64(out, text.length);
    put32(out, (uint32_t)textOff);
    put32(out, 2 /*align 4*/);
    put32(out, (uint32_t)(nTextRel ? textRelOff : 0));
    put32(out, nTextRel);
    put32(out, 0x80000400 /*PURE_INSTRUCTIONS|SOME_INSTRUCTIONS*/);
    put32(out, 0);
    put32(out, 0);
    put32(out, 0);

    putFixed(out, "__data", 16);
    putFixed(out, "__DATA", 16);
    put64(out, text.length);
    put64(out, data.length);
    put32(out, (uint32_t)(data.length ? dataOff : 0));
    put32(out, 3 /*align 8*/);
    put32(out, (uint32_t)(nDataRel ? dataRelOff : 0));
    put32(out, nDataRel);
    put32(out, 0);
    put32(out, 0);
    put32(out, 0);
    put32(out, 0);

    put32(out, 0x2 /*LC_SYMTAB*/);
    put32(out, symCmd);
    put32(out, (uint32_t)symOff);
    put32(out, (uint32_t)order.count);
    put32(out, (uint32_t)strOff);
    put32(out, (uint32_t)strtab.length);

    put32(out, 0x32 /*LC_BUILD_VERSION*/);
    put32(out, buildCmd);
    // Objects keep their historical macOS 14.0 stamp; an iOS platform set via
    // +setApplePlatform: overrides it (the sPlatform* defaults do not, so the
    // default object output stays byte-identical — ld64-diff pins it).
    if (sPlatformId == 1)
        {
        put32(out, 1);
        put32(out, 0x000E0000);
        put32(out, 0x000E0000);
        }
    else
        {
        put32(out, sPlatformId);
        put32(out, sPlatformMinos);
        put32(out, sPlatformSdk);
        }
    put32(out, 0 /*ntools*/);

    put32(out, 0xB /*LC_DYSYMTAB*/);
    put32(out, dysymCmd);
    put32(out, 0);
    put32(out, (uint32_t)nLocals); // ilocalsym, nlocalsym
    put32(out, (uint32_t)nLocals);
    put32(out, (uint32_t)(defText.count + defData.count));
    put32(out, (uint32_t)(nLocals + defText.count + defData.count));
    put32(out, (uint32_t)undef.count);
    for (int i = 0; i < 12; i++)
        put32(out, 0); // toc/module/ref/indirect/ext/loc

    while (out.length < textOff)
        put8(out, 0);
    [out appendData:text];
    while (out.length < dataOff)
        put8(out, 0);
    [out appendData:data];
    [out appendData:textRel];
    [out appendData:dataRel];
    while (out.length < symOff)
        put8(out, 0);
    for (NSUInteger i = 0; i < order.count; i++)
        {
        NSString* n = order[i];
        BOOL isUndef = (symbols[n] == nil);
        BOOL isData = [dsyms containsObject:n];
        BOOL isExt = (exports == nil) || [exports containsObject:n];
        NSArray<NSNumber*>* common = comms[n]; // @[size, log2align] or nil
        put32(out, [strx[i] unsignedIntValue]);
        put8(out, isUndef ? 0x01 : (isExt ? 0x0F : 0x0E)); // N_UNDF|N_EXT : N_SECT[|N_EXT]
        put8(out, isUndef ? 0 : (isData ? 2 : 1));         // section ordinal, 1-based
        // A COMMON carries its alignment in n_desc (GET_COMM_ALIGN: log2 align
        // in bits 8-11) and its SIZE in n_value; a plain undef leaves both zero.
        uint16_t desc = common ? (uint16_t)((common[1].unsignedIntValue & 0x0f) << 8) : 0;
        put8(out, desc & 0xff);
        put8(out, (desc >> 8) & 0xff); // n_desc
        put64(out, common ? common[0].unsignedLongLongValue
                          : (isUndef ? 0
                                     : (isData ? text.length + symbols[n].unsignedLongLongValue
                                               : symbols[n].unsignedLongLongValue)));
        }
    [out appendData:strtab];
    return out;
    }

// Read a BARE MH_OBJECT file (not an archive member). Same parse as an archive
// member — objectsInArchive: only adds the work of locating members — so an
// object we emitted and an object clang emitted arrive in the linker in exactly
// the same shape. Stage 2 of private:docs/Design/separate-compilation.md.
+ (nullable NSDictionary*)objectAtPath:(NSString*)path
    {
    NSData* d = [NSData dataWithContentsOfFile:path];
    if (d.length < 32)
        return nil;
    const uint8_t* b = d.bytes;
    uint32_t (^rd32)(uint64_t) = ^uint32_t(uint64_t o) {
      return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | ((uint32_t)b[o + 3] << 24);
    };
    uint64_t (^rd64)(uint64_t) = ^uint64_t(uint64_t o) {
      uint64_t v = 0;
      for (int i = 0; i < 8; i++)
          v |= (uint64_t)b[o + i] << (8 * i);
      return v;
    };
    if (rd32(0) != 0xFEEDFACF)
        return nil;
    return [self parseObject:b at:0 len:d.length rd32:rd32 rd64:rd64];
    }

+ (nullable NSArray<NSDictionary*>*)objectsInArchive:(NSString*)path
    {
    NSData* d = [NSData dataWithContentsOfFile:path];
    if (d.length < 8 || memcmp(d.bytes, "!<arch>\n", 8) != 0)
        return nil;
    const uint8_t* b = d.bytes;
    uint32_t (^rd32)(uint64_t) = ^uint32_t(uint64_t o) {
      return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | ((uint32_t)b[o + 3] << 24);
    };
    uint64_t (^rd64)(uint64_t) = ^uint64_t(uint64_t o) {
      uint64_t v = 0;
      for (int i = 0; i < 8; i++)
          v |= (uint64_t)b[o + i] << (8 * i);
      return v;
    };
    NSMutableArray<NSDictionary*>* objs = [NSMutableArray array];
    uint64_t p = 8;
    while (p + 60 <= d.length)
        {
        // ar header: name[16] mtime[12] uid[6] gid[6] mode[8] size[10] `\n
        char namef[17];
        memcpy(namef, b + p, 16);
        namef[16] = 0;
        char sizef[11];
        memcpy(sizef, b + p + 48, 10);
        sizef[10] = 0;
        uint64_t msize = (uint64_t)atoll(sizef);
        uint64_t data = p + 60;
        NSString* nm = [[NSString stringWithUTF8String:namef] stringByTrimmingCharactersInSet:
                                                                  [NSCharacterSet whitespaceCharacterSet]];
        uint64_t nameExtra = 0;
        // BSD long name in the data
        if ([nm hasPrefix:@"#1/"])
            {
            nameExtra = (uint64_t)[[nm substringFromIndex:3] intValue];
            nm = [[NSString alloc] initWithBytes:b + data length:nameExtra encoding:NSUTF8StringEncoding];
            nm = [nm stringByTrimmingCharactersInSet:[NSCharacterSet controlCharacterSet]];
            }
        uint64_t objStart = data + nameExtra, objLen = (msize > nameExtra) ? msize - nameExtra : 0;
        if (![nm hasPrefix:@"__.SYMDEF"] && objLen >= 32 && rd32(objStart) == XMH_MAGIC_64)
            {
            NSDictionary* obj = [self parseObject:b at:objStart len:objLen rd32:rd32 rd64:rd64];
            if (obj)
                [objs addObject:obj];
            }
        p = data + msize;
        if (p & 1)
            p++; // members are 2-byte aligned
        }
    return objs;
    }

// Parse one MH_OBJECT (at absolute offset `base`): pull the __text bytes, its
// external symbols (name→offset in __text), and its __text relocations.
+ (nullable NSDictionary*)parseObject:(const uint8_t*)b at:(uint64_t)base len:(uint64_t)len
                                 rd32:(uint32_t (^)(uint64_t))rd32
                                 rd64:(uint64_t (^)(uint64_t))rd64
    {
    if (rd32(base + 12) != 1 /*MH_OBJECT*/)
        return nil;
    uint32_t ncmds = rd32(base + 16);
    uint32_t symoff = 0, nsyms = 0, stroff = 0;
    // Section table, 1-based like nlist n_sect. Index 0 is a placeholder.
    NSMutableArray<NSDictionary*>* sects = [NSMutableArray arrayWithObject:@{}];
    uint64_t o = base + 32;
    for (uint32_t i = 0; i < ncmds; i++)
        {
        uint32_t cmd = rd32(o), csz = rd32(o + 4);
        if (cmd == XLC_SEGMENT_64)
            {
            uint32_t nsects = rd32(o + 64);
            uint64_t so = o + 72;
            for (uint32_t s = 0; s < nsects; s++)
                {
                char sn[17];
                memcpy(sn, b + so, 16);
                sn[16] = 0;
                char sg[17];
                memcpy(sg, b + so + 16, 16);
                sg[16] = 0;
                sects[sects.count] = @{@"name" : @(sn), @"seg" : @(sg), @"addr" : @(rd64(so + 32)), @"size" : @(rd64(so + 40)), @"foff" : @(base + rd32(so + 48)), @"reloff" : @(base + rd32(so + 56)), @"nreloc" : @(rd32(so + 60)), @"flags" : @(rd32(so + 64))};
                so += 80;
                }
            }
        else if (cmd == XLC_SYMTAB)
            {
            symoff = rd32(o + 8);
            nsyms = rd32(o + 12);
            stroff = rd32(o + 16);
            }
        o += csz;
        }
    int textIdx = 0;
    for (int i = 1; i < (int)sects.count; i++)
        if ([sects[i][@"name"] isEqualToString:@"__text"])
            {
            textIdx = i;
            break;
            }
    if (!textIdx)
        return nil;
    NSDictionary* ts = sects[textIdx];
    NSData* text = [NSData dataWithBytes:b + [ts[@"foff"] unsignedLongLongValue] length:[ts[@"size"] unsignedLongLongValue]];
    uint64_t textAddr = [ts[@"addr"] unsignedLongLongValue];

    // Concatenate the file-backed / zero-fill DATA sections (__data, __const,
    // __cstring, __bss/__common) into one blob; record each section's blob offset
    // so a symbol's blob position is blobOff[sect] + (value - section addr).
    NSMutableData* data = [NSMutableData data];
    NSMutableDictionary<NSNumber*, NSNumber*>* blobOff = [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber*>* dataSectIdx = [NSMutableArray array];
    // Bug 069: the ObjC runtime finds its metadata BY SECTION IDENTITY — it
    // rebinds every __objc_selrefs slot to the canonical selector at load, and
    // a selref that arrives as anonymous __data keeps its build-time pointer,
    // so every message send misses. The blob below deliberately forgets which
    // section each run came from; these ranges are what lets the linker put the
    // identity back. Name, segment and flags are carried verbatim from the
    // input object, so no table of section types has to be maintained here.
    NSMutableArray<NSDictionary*>* objcRanges = [NSMutableArray array];
    for (int i = 1; i < (int)sects.count; i++)
        {
        if (i == textIdx)
            continue;
        NSDictionary* s = sects[i];
        NSString *nm = s[@"name"], *sg = s[@"seg"];
        uint8_t stype = [s[@"flags"] unsignedIntValue] & 0xff;
        // __TEXT literal pools by SECTION TYPE, not name: clang parks float/
        // double constants in __literal4/8/16 (S_{4,8,16}BYTE_LITERALS) and
        // addresses them through PRIVATE `lCPI` labels — named relocations,
        // because .subsections_via_symbols forbids cross-atom section-relative
        // refs. Skipping these sections left the labels classified UNDEFINED
        // and the link failed on its own constant pool (blewit finding #9).
        BOOL textLiteral = [sg isEqualToString:@"__TEXT"] && (stype == 0x2 || stype == 0x3 || stype == 0x4 || stype == 0xE || stype == 0x5 || [nm isEqualToString:@"__const"] || [nm isEqualToString:@"__cstring"]);
        BOOL dataLike = [sg isEqualToString:@"__DATA"] || [sg isEqualToString:@"__DATA_CONST"] || textLiteral;
        if (!dataLike)
            continue;                               // skip __compact_unwind / __LD / debug
        uint64_t alignTo = (stype == 0xE) ? 15 : 7; // 16-byte literals keep 16-alignment
        while (data.length & alignTo)
            {
            uint8_t z = 0;
            [data appendBytes:&z length:1];
            }
        blobOff[@(i)] = @(data.length);
        [dataSectIdx addObject:@(i)];
        uint64_t sz = [s[@"size"] unsignedLongLongValue];
        if ([nm hasPrefix:@"__objc_"])
            [objcRanges addObject:@{@"name" : nm, @"seg" : sg, @"flags" : s[@"flags"], @"off" : @(data.length), @"size" : @(sz)}];
        if (stype == 0x1 || stype == 0xc || stype == 0x12)
            [data appendData:[NSMutableData dataWithLength:sz]]; // zero-fill
        else
            [data appendBytes:b + [s[@"foff"] unsignedLongLongValue] length:sz];
        }

    // Common (tentative) symbols: an `int g_x[16];` with no initialiser is a
    // COMMON — n_type N_UNDF|N_EXT, n_sect 0, n_value = its SIZE (not an address).
    // It is a DEFINITION the linker must give zero-filled storage; clang addresses
    // it through the GOT, so leaving it "undefined" makes the GOT slot bogus and
    // the first access SIGSEGVs (exactly mbedtls's ctr_drbg/entropy globals). Give
    // each one blob space here, so the symbol loop below classifies it as data.
    NSMutableDictionary<NSString*, NSNumber*>* commonOff = [NSMutableDictionary dictionary];
    // Common (tentative) sizes, so the linker can pick the LARGEST across objects
    // (a C linker merges commons that way; last-object-wins mis-sized a table
    // linked def-then-use — bug 177).
    NSMutableDictionary<NSString*, NSNumber*>* commonSize = [NSMutableDictionary dictionary];
    for (uint32_t i = 0; i < nsyms; i++)
        {
        uint64_t e = base + symoff + (uint64_t)i * 16;
        uint8_t type = b[e + 4], sect = b[e + 5];
        uint16_t desc = (uint16_t)(b[e + 6] | (b[e + 7] << 8));
        uint64_t val = rd64(e + 8);
        if ((type & 0x0e) != XN_UNDF || !(type & XN_EXT) || sect != 0 || val == 0)
            continue;
        NSString* n = [NSString stringWithUTF8String:(const char*)(b + base + stroff + rd32(e))] ?: @"";
        if (!n.length || commonOff[n])
            continue;
        uint32_t align = (desc >> 8) & 0x0f; // GET_COMM_ALIGN: log2, in n_desc
        uint64_t amask = ((uint64_t)1 << (align ? align : 3)) - 1;
        if (amask < 7)
            amask = 7;
        while (data.length & amask)
            {
            uint8_t z = 0;
            [data appendBytes:&z length:1];
            }
        commonOff[n] = @(data.length);
        commonSize[n] = @(val);
        [data appendData:[NSMutableData dataWithLength:(NSUInteger)val]];
        }

    // Per-symbol definition info, parallel to `symnames` (so a reloc's r_symbolnum
    // resolves): where = 0 undef / 1 text / 2 data; off = offset in text or the data
    // blob; ext = N_EXT. `syms`/`dsyms` keep only the EXTERNAL defs — that's what the
    // pull decision keys off (a needed symbol is an external reference); locals
    // (e.g. `l_.str`) are registered per-object by the caller to avoid name clashes.
    NSMutableDictionary<NSString*, NSNumber*>* syms = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* dsyms = [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* symnames = [NSMutableArray array];
    NSMutableArray<NSDictionary*>* symdefs = [NSMutableArray array];
    for (uint32_t i = 0; i < nsyms; i++)
        {
        uint64_t e = base + symoff + (uint64_t)i * 16;
        uint32_t strx = rd32(e);
        uint8_t type = b[e + 4], sect = b[e + 5];
        uint64_t val = rd64(e + 8);
        NSString* n = [NSString stringWithUTF8String:(const char*)(b + base + stroff + strx)] ?: @"";
        symnames[symnames.count] = n;
        int where = 0;
        uint64_t off = 0;
        BOOL ext = (type & XN_EXT) != 0;
        if ((type & 0xe) == XN_SECT)
            {
            if (sect == textIdx)
                {
                where = 1;
                off = val - textAddr;
                }
            else if (blobOff[@(sect)])
                {
                where = 2;
                off = [blobOff[@(sect)] unsignedLongLongValue] + (val - [sects[sect][@"addr"] unsignedLongLongValue]);
                }
            }
        else if (commonOff[n] != nil)
            {
            where = 2;
            off = [commonOff[n] unsignedLongLongValue]; // common → its allocated blob slot
            }
        symdefs[symdefs.count] = @{@"ext" : @(ext), @"where" : @(where), @"off" : @(off)};
        if (n.length && ext && where == 1)
            syms[n] = @(off);
        else if (n.length && ext && where == 2)
            dsyms[n] = @(off);
        }
    NSMutableArray<NSDictionary*>* relocs = [NSMutableArray array];
    uint64_t treloff = [ts[@"reloff"] unsignedLongLongValue];
    uint32_t tnreloc = [ts[@"nreloc"] unsignedIntValue];
    for (uint32_t i = 0; i < tnreloc; i++)
        {
        uint64_t r = treloff + (uint64_t)i * 8;
        int32_t addr = (int32_t)rd32(r);
        uint32_t info = rd32(r + 4);
        relocs[relocs.count] = @{@"off" : @(addr), @"symnum" : @(info & 0xFFFFFF), @"pcrel" : @((info >> 24) & 1), @"len" : @((info >> 25) & 3), @"extern" : @((info >> 27) & 1), @"type" : @((info >> 28) & 0xF)};
        }
    // Relocations inside the DATA sections (e.g. a `.quad _sym` pointer-table slot →
    // ARM64_RELOC_UNSIGNED). Offsets are rebased from section-relative to
    // blob-relative so the caller only has to add where it appended the blob.
    NSMutableArray<NSDictionary*>* datarelocs = [NSMutableArray array];
    for (NSNumber* si in dataSectIdx)
        {
        NSDictionary* s = sects[si.intValue];
        uint64_t ro = [s[@"reloff"] unsignedLongLongValue];
        uint32_t nr = [s[@"nreloc"] unsignedIntValue];
        uint64_t bo = [blobOff[si] unsignedLongLongValue];
        for (uint32_t i = 0; i < nr; i++)
            {
            uint64_t r = ro + (uint64_t)i * 8;
            int32_t addr = (int32_t)rd32(r);
            uint32_t info = rd32(r + 4);
            datarelocs[datarelocs.count] = @{@"off" : @(bo + (uint64_t)addr), @"symnum" : @(info & 0xFFFFFF), @"pcrel" : @((info >> 24) & 1), @"len" : @((info >> 25) & 3), @"extern" : @((info >> 27) & 1), @"type" : @((info >> 28) & 0xF)};
            }
        }
    (void)len;
    return @{@"text" : text, @"symbols" : syms, @"data" : data, @"datasyms" : dsyms, @"relocs" : relocs, @"datarelocs" : datarelocs, @"symnames" : symnames, @"symdefs" : symdefs, @"objcranges" : objcRanges, @"commons" : commonSize};
    }

+ (NSData*)executableFromText:(NSData*)textIn
                  entryOffset:(uint64_t)entryOffset
                      symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                         data:(NSData*)dataIn
                  dataSymbols:(NSSet<NSString*>*)dataSymbols
                       fixups:(NSArray<XAArm64Fixup*>*)fixups
                       dylibs:(NSArray<NSDictionary*>*)dylibs
                       rpaths:(NSArray<NSString*>*)rpaths
                modInitLength:(NSUInteger)modInitLength
                 objcSections:(NSArray<NSDictionary*>*)objcSections
    {
    if (!dylibs)
        dylibs = @[];
    if (!objcSections)
        objcSections = @[];
    if (!rpaths)
        rpaths = @[];
    NSMutableData* text = [textIn mutableCopy];
    NSMutableData* data = dataIn ? [dataIn mutableCopy] : [NSMutableData data];
    if (!dataSymbols)
        dataSymbols = [NSSet set];
    BOOL hasData = data.length > 0;
    // Bug 066: the tail of __data is the __mod_init_func pointer array. Same
    // bytes, same addresses, same rebases — it is described by its OWN section
    // header so dyld knows to CALL them. Without one it ran nothing, silently.
    NSUInteger miLen = (modInitLength <= data.length) ? modInitLength : 0;
    NSUInteger dOnly = data.length - miLen;
    // Bug 069: the ObjC sections were carved out of the blob by the linker's
    // repartition and sit between the ordinary data and the mod-init tail, so
    // __data ends where the first of them begins.
    for (NSDictionary* osec in objcSections)
        {
        NSUInteger off = [osec[@"off"] unsignedIntegerValue];
        if (off < dOnly)
            dOnly = off;
        }
    BOOL hasModInit = miLen > 0;
    BOOL hasDataSect = dOnly > 0;

    // ── 1. Collect imports from Branch26 fixups to non-local symbols ──
    NSMutableArray<NSString*>* imports = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSNumber*>* importIndex = [NSMutableDictionary dictionary];
    for (XAArm64Fixup* f in fixups)
        {
        // A call to an undefined symbol (→ stub), a GOT-indirect ref to an
        // imported DATA symbol (→ just the __got slot), or a POINTER SLOT in
        // __data holding an undefined symbol's address (→ a dyld bind for
        // that slot) all need an import entry. The pointer-slot case is a C
        // function-pointer table in data — `void *(*tab[])() = { malloc }` —
        // which used to be skipped entirely: the slot linked as NULL with no
        // diagnostic and the first call through it jumped to 0 (blewit
        // finding #7). With a bind entry, dyld fills the slot at load — or
        // fails LOUDLY naming the symbol, the same diagnosis calls get.
        BOOL wantsImport = f.kind == XAArm64FixupBranch26 || f.kind == XAArm64FixupGotPage21 || f.kind == XAArm64FixupGotPageOff12 || f.kind == XAArm64FixupPointer64;
        if (!wantsImport)
            continue;
        if (symbols[f.symbol])
            continue; // resolved locally already
        if (!importIndex[f.symbol])
            {
            importIndex[f.symbol] = @(imports.count);
            [imports addObject:f.symbol];
            }
        }
    NSUInteger nimp = imports.count;
    BOOL hasImp = nimp > 0;
    BOOL hasDataSeg = hasData || hasImp;

    // Per-import dylib ordinal: libSystem = 1, each entry of `dylibs` = 2,3,...
    // A symbol an imported dylib exports binds to that dylib; the rest (the C
    // runtime calls) stay with libSystem.
    NSMutableArray<NSNumber*>* importOrdinal = [NSMutableArray array];
    for (NSString* sym in imports)
        {
        uint8_t ord = 1;
        for (NSUInteger di = 0; di < dylibs.count; di++)
            {
            NSSet* ex = dylibs[di][@"symbols"];
            if ([ex containsObject:sym])
                {
                ord = (uint8_t)(2 + di);
                break;
                }
            }
        [importOrdinal addObject:@(ord)];
        }

    // ── 2. Layout ──  (vmaddr == VMBASE + file offset throughout)
    uint64_t textOffset = PAGE; // header slack for codesign
    uint64_t stubsOffset = roundUp(textOffset + text.length, 4);
    uint64_t stubsSize = nimp * STUB_SZ;
    uint64_t textSegEnd = roundUp(stubsOffset + stubsSize, PAGE);
    uint64_t textAddr = VMBASE + textOffset;
    uint64_t stubsAddr = VMBASE + stubsOffset;

    uint64_t dataSegFileOff = textSegEnd;                                          // __DATA starts here
    uint64_t dataProgOffset = dataSegFileOff;                                      // __data section
    uint64_t gotOffset = roundUp(dataProgOffset + (hasData ? data.length : 0), 8); // __got after __data
    uint64_t gotSize = nimp * GOT_SZ;
    uint64_t dataSegEnd = hasDataSeg ? roundUp(gotOffset + gotSize, PAGE) : textSegEnd;
    uint64_t dataAddr = VMBASE + dataProgOffset;
    uint64_t gotAddr = VMBASE + gotOffset;
    uint64_t gotOffInSeg = gotOffset - dataSegFileOff;

    uint64_t linkeditOff = dataSegEnd;
    uint64_t linkeditAddr = VMBASE + linkeditOff;

    // address of a defined symbol (text- or data-section relative)
    uint64_t (^symAddr)(NSString*) = ^uint64_t(NSString* nm) {
      uint64_t off = symbols[nm].unsignedLongLongValue;
      return [dataSymbols containsObject:nm] ? (dataAddr + off) : (textAddr + off);
    };

    // ── 3. Patch fixups in the text ──
    uint8_t* tb = (uint8_t*)text.mutableBytes;
    uint32_t (^rdw)(uint64_t) = ^uint32_t(uint64_t o) {
      return tb[o] | (tb[o + 1] << 8) | (tb[o + 2] << 16) | ((uint32_t)tb[o + 3] << 24);
    };
    void (^wrw)(uint64_t, uint32_t) = ^(uint64_t o, uint32_t w) {
      tb[o] = (uint8_t)w;
      tb[o + 1] = (uint8_t)(w >> 8);
      tb[o + 2] = (uint8_t)(w >> 16);
      tb[o + 3] = (uint8_t)(w >> 24);
    };
    for (XAArm64Fixup* f in fixups)
        {
        // call -> import stub
        if (f.kind == XAArm64FixupBranch26 && !symbols[f.symbol])
            {
            NSUInteger idx = importIndex[f.symbol].unsignedIntegerValue;
            uint64_t stubAddr = stubsAddr + idx * STUB_SZ;
            int32_t rel = (int32_t)(((int64_t)stubAddr - (int64_t)(textAddr + f.offset)) >> 2);
            wrw(f.offset, (rdw(f.offset) & 0xFC000000u) | ((uint32_t)rel & 0x03FFFFFFu));
            }
        // call -> local (static-linked)
        else if (f.kind == XAArm64FixupBranch26 && symbols[f.symbol])
            {
            int32_t rel = (int32_t)(((int64_t)symAddr(f.symbol) + f.addend - (int64_t)(textAddr + f.offset)) >> 2);
            wrw(f.offset, (rdw(f.offset) & 0xFC000000u) | ((uint32_t)rel & 0x03FFFFFFu));
            }
        // adrp <sym>@PAGE
        else if (f.kind == XAArm64FixupPage21 && symbols[f.symbol])
            {
            uint64_t s = symAddr(f.symbol) + (uint64_t)f.addend;
            int64_t d = (int64_t)((s & ~0xFFFull) - ((textAddr + f.offset) & ~0xFFFull));
            int64_t imm = d >> 12;
            uint32_t w = rdw(f.offset) & ~((3u << 29) | (0x7FFFFu << 5));
            wrw(f.offset, w | ((uint32_t)(imm & 3) << 29) | ((uint32_t)((imm >> 2) & 0x7FFFF) << 5));
            }
        // <sym>@PAGEOFF (add or scaled ld/st)
        else if (f.kind == XAArm64FixupPageOff12 && symbols[f.symbol])
            {
            uint32_t imm12 = (uint32_t)(((symAddr(f.symbol) + (uint64_t)f.addend) & 0xFFF) >> f.scale);
            wrw(f.offset, (rdw(f.offset) & ~(0xFFFu << 10)) | (imm12 << 10));
            }
        // adrp <sym>@GOTPAGE
        else if (f.kind == XAArm64FixupGotPage21 && !symbols[f.symbol])
            {
            uint64_t slot = gotAddr + importIndex[f.symbol].unsignedIntegerValue * GOT_SZ;
            int64_t d = (int64_t)((slot & ~0xFFFull) - ((textAddr + f.offset) & ~0xFFFull));
            int64_t imm = d >> 12;
            uint32_t w = rdw(f.offset) & ~((3u << 29) | (0x7FFFFu << 5));
            wrw(f.offset, w | ((uint32_t)(imm & 3) << 29) | ((uint32_t)((imm >> 2) & 0x7FFFF) << 5));
            }
        // ldr <sym>@GOTPAGEOFF
        else if (f.kind == XAArm64FixupGotPageOff12 && !symbols[f.symbol])
            {
            uint64_t slot = gotAddr + importIndex[f.symbol].unsignedIntegerValue * GOT_SZ;
            wrw(f.offset, (rdw(f.offset) & ~(0xFFFu << 10)) | ((uint32_t)((slot & 0xFFF) >> 3) << 10));
            }
        }
    // ── 3b. Patch .quad <symbol> pointer slots in __data ──
    // A LOCALLY-defined symbol's slot gets the absolute address + a rebase
    // (dyld adds the slide); an UNDEFINED symbol's slot stays zero and gets a
    // dyld BIND instead — dyld writes the resolved address at load (finding
    // #7: these used to be skipped, silently linking the slot as null).
    NSMutableArray<NSNumber*>* rebaseOffs = [NSMutableArray array]; // __data offsets
    NSMutableArray<XAArm64Fixup*>* dataBinds = [NSMutableArray array];
    uint8_t* db = (uint8_t*)data.mutableBytes;
    for (XAArm64Fixup* f in fixups)
        {
        if (f.kind != XAArm64FixupPointer64)
            continue;
        if (!symbols[f.symbol])
            {
            if (importIndex[f.symbol])
                [dataBinds addObject:f];
            continue;
            }
        uint64_t s = symAddr(f.symbol) + (uint64_t)f.addend; // unslid VM address
        for (int i = 0; i < 8; i++)
            db[f.offset + i] = (uint8_t)(s >> (8 * i));
        [rebaseOffs addObject:@(f.offset)]; // dyld adds the slide
        }
    BOOL hasRebase = rebaseOffs.count > 0;
    [rebaseOffs sortUsingComparator:^(NSNumber* a, NSNumber* b) {
      return [a compare:b];
    }];
    [dataBinds sortUsingComparator:^(XAArm64Fixup* a, XAArm64Fixup* b) {
      return a.offset < b.offset   ? NSOrderedAscending
             : a.offset > b.offset ? NSOrderedDescending
                                   : NSOrderedSame;
    }];

    // stub code
    NSMutableData* stubs = [NSMutableData data];
    for (NSUInteger i = 0; i < nimp; i++)
        emitStub(stubs, stubsAddr + i * STUB_SZ, gotAddr + i * GOT_SZ);

    // ── 4. __LINKEDIT contents ──
    // dyld_info rebase stream: each .quad-symbol slot in __data is a pointer dyld
    // slides for the PIE. (__data is the first section of __DATA, so its section
    // offset == its segment offset.)
    NSMutableData* rebase = [NSMutableData data];
    if (hasRebase)
        {
        put8(rebase, REBASE_SET_TYPE_IMM | REBASE_TYPE_POINTER);
        for (NSNumber* o in rebaseOffs)
            {
            put8(rebase, REBASE_SET_SEG_OFF_ULEB | 2); // segment 2 = __DATA
            putULEB(rebase, o.unsignedLongLongValue);
            put8(rebase, REBASE_DO_IMM_TIMES | 1);
            }
        put8(rebase, REBASE_DONE);
        while (rebase.length & 7)
            put8(rebase, 0);
        }
    // bind stream (the got binds), others empty; export(empty)
    NSMutableData* bind = [NSMutableData data];
    if (hasImp)
        {
        uint8_t curOrd = 0; // force an initial SET
        for (NSUInteger i = 0; i < nimp; i++)
            {
            uint8_t ord = importOrdinal[i].unsignedCharValue;
            if (ord != curOrd)
                {
                put8(bind, BIND_SET_DYLIB_ORDINAL_IMM | ord);
                curOrd = ord;
                }
            put8(bind, BIND_SET_SYMBOL_FLAGS | 0);
            const char* nm = imports[i].UTF8String;
            [bind appendBytes:nm length:strlen(nm) + 1];
            put8(bind, BIND_SET_TYPE_IMM | BIND_TYPE_POINTER);
            put8(bind, BIND_SET_SEG_OFF_ULEB | 2);   // segment 2 = __DATA
            putULEB(bind, gotOffInSeg + i * GOT_SZ); // __got sits after __data
            put8(bind, BIND_DO_BIND);
            }
        // Data-slot binds (finding #7): each undefined-symbol pointer slot in
        // __data binds in place. __data is the FIRST section of __DATA, so a
        // section offset is a segment offset as-is. A non-zero addend rides
        // BIND_SET_ADDEND_SLEB (and is reset after, since it's sticky state).
        for (XAArm64Fixup* f in dataBinds)
            {
            NSUInteger i = importIndex[f.symbol].unsignedIntegerValue;
            uint8_t ord = importOrdinal[i].unsignedCharValue;
            put8(bind, BIND_SET_DYLIB_ORDINAL_IMM | ord);
            put8(bind, BIND_SET_SYMBOL_FLAGS | 0);
            const char* nm = imports[i].UTF8String;
            [bind appendBytes:nm length:strlen(nm) + 1];
            put8(bind, BIND_SET_TYPE_IMM | BIND_TYPE_POINTER);
            if (f.addend)
                {
                put8(bind, BIND_SET_ADDEND_SLEB);
                putSLEB(bind, f.addend);
                }
            put8(bind, BIND_SET_SEG_OFF_ULEB | 2); // segment 2 = __DATA
            putULEB(bind, f.offset);
            put8(bind, BIND_DO_BIND);
            if (f.addend)
                {
                put8(bind, BIND_SET_ADDEND_SLEB);
                putSLEB(bind, 0);
                }
            }
        put8(bind, BIND_DONE);
        while (bind.length & 7)
            put8(bind, 0);
        }

    // symbol table: [defined locals ...][undef imports ...]
    // Sorted by OFFSET, ties broken on the NAME. Two symbols can share an
    // offset — a text label at 0 and a data label at 0 always do — and leaving
    // that tie to `allKeys` would make the symbol table's order depend on how
    // the dictionary happened to hash.
    NSArray* defNames = [symbols.allKeys sortedArrayUsingComparator:^(NSString* a, NSString* b) {
      NSComparisonResult r = [symbols[a] compare:symbols[b]];
      return r != NSOrderedSame ? r : [a compare:b];
    }];
    NSMutableData* strtab = [NSMutableData data];
    put8(strtab, 0);
    NSMutableData* nlist = [NSMutableData data];
    uint8_t dataSect = (uint8_t)(1 + (hasImp ? 1 : 0) + 1); // __text[+__stubs] then __data
    for (NSString* nm in defNames)
        {
        uint32_t strx = (uint32_t)strtab.length;
        const char* c = nm.UTF8String;
        [strtab appendBytes:c length:strlen(c) + 1];
        BOOL inData = [dataSymbols containsObject:nm];
        put32(nlist, strx);
        put8(nlist, XN_SECT);
        put8(nlist, inData ? dataSect : 1);
        put8(nlist, 0);
        put8(nlist, 0);
        put64(nlist, symAddr(nm));
        }
    for (NSUInteger i = 0; i < imports.count; i++)
        {
        NSString* nm = imports[i];
        uint32_t strx = (uint32_t)strtab.length;
        const char* c = nm.UTF8String;
        [strtab appendBytes:c length:strlen(c) + 1];
        put32(nlist, strx);
        put8(nlist, XN_UNDF | XN_EXT);
        put8(nlist, 0);
        put8(nlist, 0);
        put8(nlist, importOrdinal[i].unsignedCharValue); // n_desc: library ordinal
        put64(nlist, 0);
        }
    uint32_t ndef = (uint32_t)defNames.count, nsyms = (uint32_t)(defNames.count + imports.count);
    // indirect symbol table: one entry per got slot -> symtab index of that import
    NSMutableData* indirect = [NSMutableData data];
    for (NSUInteger i = 0; i < nimp; i++)
        put32(indirect, ndef + (uint32_t)i);

    // linkedit layout: rebase | bind | nlist | indirect | strtab
    uint64_t rebaseOff = linkeditOff;
    uint64_t bindOff = rebaseOff + rebase.length;
    uint64_t symoff = bindOff + bind.length;
    uint64_t indOff = symoff + nlist.length;
    uint64_t stroff = indOff + indirect.length;
    uint64_t strsize = roundUp(strtab.length, 8);
    while (strtab.length < strsize)
        put8(strtab, 0);
    // The ad-hoc code signature sits at the end of __LINKEDIT; codeLimit is its
    // start (everything before it is hashed). Size it up front so it fits the
    // load command and the segment.
    NSString* sigIdent = @"xtc";
    uint64_t sigOffset = roundUp(stroff + strsize, 16);
    uint32_t nCodeSlots = (uint32_t)((sigOffset + 4095) / 4096);
    uint32_t sigSize = 12 + 8 + 88 + (uint32_t)(sigIdent.length + 1) + nCodeSlots * 32;
    // The signature must be the LAST bytes of the file — iOS device install
    // and Apple's codesign reject any trailing bytes after it (macOS load
    // tolerates them, which is why this went unnoticed). So the file ends
    // exactly at the signature: __LINKEDIT's FILESIZE is exact, its VMSIZE is
    // page-rounded (in-memory only). (bug 148)
    uint64_t linkeditFilesz = (sigOffset + sigSize) - linkeditOff;
    uint64_t linkeditVmsz = roundUp(linkeditFilesz, PAGE);

    // ── 5. Command sizes ──
    const char *dyld = "/usr/lib/dyld", *libSys = "/usr/lib/libSystem.B.dylib";
    uint32_t nDataSects = (hasDataSect ? 1 : 0) + (hasModInit ? 1 : 0) + (hasImp ? 1 : 0) + (uint32_t)objcSections.count; // bug 069
    uint32_t szPagezero = 72, szTextSeg = 72 + 80 * (1 + (hasImp ? 1 : 0)), szDataSeg = 72 + 80 * nDataSects, szLink = 72;
    // Entry is LC_MAIN. (LC_UNIXTHREAD is NOT an option here: modern macOS dyld
    // rejects a dynamically-linked main executable that lacks LC_MAIN — "main
    // executable is missing LC_MAIN" — so owning the entry would require a fully
    // static binary with no libSystem, which we deliberately depend on.)
    uint32_t szDyldInfo = 48, szDyld = (uint32_t)roundUp(12 + strlen(dyld) + 1, 8), szMain = 24;
    uint32_t szDylib = (uint32_t)roundUp(24 + strlen(libSys) + 1, 8), szSym = 24, szDysym = 80, szBuild = 24, szUUID = 24, szCodeSig = 16;
    BOOL hasDyldInfo = hasImp || hasRebase; // LC_DYLD_INFO if either stream is non-empty
    // extra LC_LOAD_DYLIB per imported dylib + LC_RPATH per search path
    uint32_t szExtraDylibs = 0;
    for (NSDictionary* dl in dylibs)
        szExtraDylibs += (uint32_t)roundUp(24 + strlen([dl[@"install"] UTF8String]) + 1, 8);
    uint32_t szRpaths = 0;
    for (NSString* rp in rpaths)
        szRpaths += (uint32_t)roundUp(12 + strlen(rp.UTF8String) + 1, 8);
    uint32_t ncmds = 10 + (hasDataSeg ? 1 : 0) + (hasDyldInfo ? 1 : 0) + 1 // +LC_CODE_SIGNATURE
                     + (uint32_t)dylibs.count + (uint32_t)rpaths.count;
    uint32_t sizeofcmds = szPagezero + szTextSeg + (hasDataSeg ? szDataSeg : 0) + szLink + (hasDyldInfo ? szDyldInfo : 0) + szDyld + szMain + szDylib + szSym + szDysym + szBuild + szUUID + szCodeSig + szExtraDylibs + szRpaths;

    // ── 6. Emit ──
    NSMutableData* out = [NSMutableData data];
    put32(out, XMH_MAGIC_64);
    put32(out, XCPU_TYPE_ARM64);
    put32(out, 0);
    put32(out, XMH_EXECUTE);
    put32(out, ncmds);
    put32(out, sizeofcmds);
    put32(out, XMH_NOUNDEFS | XMH_DYLDLINK | XMH_TWOLEVEL | XMH_PIE);
    put32(out, 0);

    // __PAGEZERO
    put32(out, XLC_SEGMENT_64);
    put32(out, szPagezero);
    putFixed(out, "__PAGEZERO", 16);
    put64(out, 0);
    put64(out, VMBASE);
    put64(out, 0);
    put64(out, 0);
    put32(out, 0);
    put32(out, 0);
    put32(out, 0);
    put32(out, 0);

    // __TEXT (+ __text [+ __stubs])
    put32(out, XLC_SEGMENT_64);
    put32(out, szTextSeg);
    putFixed(out, "__TEXT", 16);
    put64(out, VMBASE);
    put64(out, textSegEnd);
    put64(out, 0);
    put64(out, textSegEnd);
    put32(out, XVM_READ | XVM_EXEC);
    put32(out, XVM_READ | XVM_EXEC);
    put32(out, hasImp ? 2 : 1);
    put32(out, 0);
    putFixed(out, "__text", 16);
    putFixed(out, "__TEXT", 16);
    put64(out, textAddr);
    put64(out, text.length);
    put32(out, (uint32_t)textOffset);
    put32(out, 2);
    put32(out, 0);
    put32(out, 0);
    put32(out, XS_ATTR_PURE_INSTRUCTIONS | XS_ATTR_SOME_INSTRUCTIONS);
    put32(out, 0);
    put32(out, 0);
    put32(out, 0);
    if (hasImp)
        {
        putFixed(out, "__stubs", 16);
        putFixed(out, "__TEXT", 16);
        put64(out, stubsAddr);
        put64(out, stubsSize);
        put32(out, (uint32_t)stubsOffset);
        put32(out, 2);
        put32(out, 0);
        put32(out, 0);
        put32(out, XS_ATTR_PURE_INSTRUCTIONS | XS_ATTR_SOME_INSTRUCTIONS);
        put32(out, 0);
        put32(out, 0);
        put32(out, 0);
        }

    // __DATA (+ __data + __got)
    if (hasDataSeg)
        {
        uint64_t segSz = dataSegEnd - dataSegFileOff;
        put32(out, XLC_SEGMENT_64);
        put32(out, szDataSeg);
        putFixed(out, "__DATA", 16);
        put64(out, VMBASE + dataSegFileOff);
        put64(out, segSz);
        put64(out, dataSegFileOff);
        put64(out, segSz);
        put32(out, XVM_READ | XVM_WRITE);
        put32(out, XVM_READ | XVM_WRITE);
        put32(out, nDataSects);
        put32(out, 0);
        if (hasDataSect)
            {
            putFixed(out, "__data", 16);
            putFixed(out, "__DATA", 16);
            put64(out, dataAddr);
            put64(out, dOnly);
            put32(out, (uint32_t)dataProgOffset);
            put32(out, 3);
            put32(out, 0);
            put32(out, 0);
            put32(out, XS_REGULAR);
            put32(out, 0);
            put32(out, 0);
            put32(out, 0);
            }
        // Bug 069: the ObjC metadata, each with the segment, type and
        // attributes its input object gave it. The runtime locates
        // __objc_selrefs and friends BY SECTION and rebinds each selref to the
        // canonical selector at load; delivered as anonymous __data they keep
        // their build-time pointers and every message send misses. They are
        // emitted inside __DATA's span because that is where the blob lives —
        // the section's own `segname` is preserved for the runtime to read.
        for (NSDictionary* osec in objcSections)
            {
            putFixed(out, osec[@"name"] ? [osec[@"name"] UTF8String] : "__objc", 16);
            // The segname must name the segment that actually CONTAINS these
            // bytes, which is __DATA — the blob lives there. Carrying the
            // input object's original segname through (`__TEXT` for the
            // cstring pools) produced a header otool reports as "does not
            // match segment": true of the file, and the kind of latent
            // malformedness that is fine until something reads it properly.
            // The runtime keys on the section NAME for the __DATA metadata it
            // scans; the __TEXT-origin pools (__objc_methname and friends) are
            // only ever reached through pointers, never looked up by segment.
            putFixed(out, "__DATA", 16);
            NSUInteger ooff = [osec[@"off"] unsignedIntegerValue];
            NSUInteger osz = [osec[@"size"] unsignedIntegerValue];
            put64(out, dataAddr + ooff);
            put64(out, osz);
            put32(out, (uint32_t)(dataProgOffset + ooff));
            put32(out, 3);
            put32(out, 0);
            put32(out, 0);
            put32(out, [osec[@"flags"] unsignedIntValue]);
            put32(out, 0);
            put32(out, 0);
            put32(out, 0);
            }
        // Bug 066: the load-time constructors. Same segment, same bytes, right
        // after __data — only the section TYPE differs, and it is what makes
        // dyld call them instead of ignoring them.
        if (hasModInit)
            {
            putFixed(out, "__mod_init_func", 16);
            putFixed(out, "__DATA", 16);
            put64(out, dataAddr + dOnly);
            put64(out, miLen);
            put32(out, (uint32_t)(dataProgOffset + dOnly));
            put32(out, 3);
            put32(out, 0);
            put32(out, 0);
            put32(out, XS_MOD_INIT_FUNC_POINTERS);
            put32(out, 0);
            put32(out, 0);
            put32(out, 0);
            }
        if (hasImp)
            {
            putFixed(out, "__got", 16);
            putFixed(out, "__DATA", 16);
            put64(out, gotAddr);
            put64(out, gotSize);
            put32(out, (uint32_t)gotOffset);
            put32(out, 3);
            put32(out, 0);
            put32(out, 0);
            put32(out, XS_NON_LAZY_SYMBOL_POINTERS);
            put32(out, 0 /*reserved1: indirect index*/);
            put32(out, 0);
            put32(out, 0);
            }
        }

    // __LINKEDIT
    put32(out, XLC_SEGMENT_64);
    put32(out, szLink);
    putFixed(out, "__LINKEDIT", 16);
    put64(out, linkeditAddr);
    put64(out, linkeditVmsz);
    put64(out, linkeditOff);
    put64(out, linkeditFilesz);
    put32(out, XVM_READ);
    put32(out, XVM_READ);
    put32(out, 0);
    put32(out, 0);

    // LC_DYLD_INFO_ONLY
    if (hasDyldInfo)
        {
        put32(out, XLC_DYLD_INFO_ONLY);
        put32(out, szDyldInfo);
        put32(out, (uint32_t)(hasRebase ? rebaseOff : 0));
        put32(out, (uint32_t)rebase.length); // rebase
        put32(out, (uint32_t)(hasImp ? bindOff : 0));
        put32(out, (uint32_t)bind.length); // bind
        put32(out, 0);
        put32(out, 0); // weak bind
        put32(out, 0);
        put32(out, 0); // lazy bind
        put32(out, 0);
        put32(out, 0); // export
        }

    // LC_LOAD_DYLINKER
    put32(out, XLC_LOAD_DYLINKER);
    put32(out, szDyld);
    put32(out, 12);
    putFixed(out, dyld, (int)(szDyld - 12));
    // LC_MAIN (entryoff = file offset; libSystem's start calls it, then exit()).
    put32(out, XLC_MAIN);
    put32(out, szMain);
    put64(out, textOffset + entryOffset);
    put64(out, 0);
    // LC_LOAD_DYLIB libSystem (ordinal 1)
    put32(out, XLC_LOAD_DYLIB);
    put32(out, szDylib);
    put32(out, 24);
    put32(out, 2);
    put32(out, 0x510000);
    put32(out, 0x10000);
    putFixed(out, libSys, (int)(szDylib - 24));
    // LC_LOAD_DYLIB per imported dylib (ordinals 2..), in ordinal order
    for (NSDictionary* dl in dylibs)
        {
        const char* inm = [dl[@"install"] UTF8String];
        uint32_t sz = (uint32_t)roundUp(24 + strlen(inm) + 1, 8);
        put32(out, XLC_LOAD_DYLIB);
        put32(out, sz);
        put32(out, 24);
        put32(out, 2);
        put32(out, 0x10000);
        put32(out, 0x10000);
        putFixed(out, inm, (int)(sz - 24));
        }
    // LC_RPATH search paths (so @rpath/<lib> resolves beside the binary)
    for (NSString* rp in rpaths)
        {
        const char* rpc = rp.UTF8String;
        uint32_t sz = (uint32_t)roundUp(12 + strlen(rpc) + 1, 8);
        put32(out, XLC_RPATH);
        put32(out, sz);
        put32(out, 12);
        putFixed(out, rpc, (int)(sz - 12));
        }
    // LC_SYMTAB
    put32(out, XLC_SYMTAB);
    put32(out, szSym);
    put32(out, (uint32_t)symoff);
    put32(out, nsyms);
    put32(out, (uint32_t)stroff);
    put32(out, (uint32_t)strtab.length);
    // LC_DYSYMTAB
    put32(out, XLC_DYSYMTAB);
    put32(out, szDysym);
    put32(out, 0);
    put32(out, ndef); // ilocalsym,nlocalsym  (treat defined as locals)
    put32(out, ndef);
    put32(out, 0); // iextdefsym,nextdefsym
    put32(out, ndef);
    put32(out, (uint32_t)nimp); // iundefsym,nundefsym
    put32(out, 0);
    put32(out, 0); // toc
    put32(out, 0);
    put32(out, 0); // modtab
    put32(out, 0);
    put32(out, 0); // extrefsym
    put32(out, (uint32_t)(hasImp ? indOff : 0));
    put32(out, (uint32_t)nimp); // indirectsym off/count
    put32(out, 0);
    put32(out, 0); // extrel
    put32(out, 0);
    put32(out, 0); // locrel
    // LC_BUILD_VERSION
    put32(out, XLC_BUILD_VERSION);
    put32(out, szBuild);
    put32(out, sPlatformId);
    put32(out, sPlatformMinos);
    put32(out, sPlatformSdk);
    put32(out, 0);
    // LC_UUID
    put32(out, XLC_UUID);
    put32(out, szUUID);
    for (int i = 0; i < 16; i++)
        put8(out, 0);
    // LC_CODE_SIGNATURE — points at the signature area at the end of __LINKEDIT
    put32(out, XLC_CODE_SIGNATURE);
    put32(out, szCodeSig);
    put32(out, (uint32_t)sigOffset);
    put32(out, sigSize);

    NSAssert(out.length == 32 + sizeofcmds, @"cmds %lu != %u", (unsigned long)out.length, 32 + sizeofcmds);

    // ── 7. File body ──
    while (out.length < textOffset)
        put8(out, 0);
    [out appendData:text];
    while (out.length < stubsOffset)
        put8(out, 0);
    [out appendData:stubs];
    if (hasData)
        {
        while (out.length < dataProgOffset)
            put8(out, 0);
        [out appendData:data];
        }
    // got: zeros, bound by dyld
    if (hasImp)
        {
        while (out.length < gotOffset)
            put8(out, 0);
        for (NSUInteger i = 0; i < gotSize; i++)
            put8(out, 0);
        }
    while (out.length < linkeditOff)
        put8(out, 0);
    [out appendData:rebase];
    [out appendData:bind];
    [out appendData:nlist];
    [out appendData:indirect];
    [out appendData:strtab];

    // ── 8. Ad-hoc code signature ──  hash [0, sigOffset), append the SuperBlob.
    while (out.length < sigOffset)
        put8(out, 0);
    NSData* sig = buildAdhocSignature(out.bytes, sigOffset, sigIdent, textSegEnd);
    [out appendData:sig];
    while (out.length < linkeditOff + linkeditFilesz)
        put8(out, 0);
    return out;
    }

+ (NSData*)dylibFromText:(NSData*)textIn
             installName:(NSString*)installName
                 exports:(NSSet<NSString*>*)exports
                   iface:(NSData*)ifaceIn
                 symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                    data:(NSData*)dataIn
             dataSymbols:(NSSet<NSString*>*)dataSymbols
                  fixups:(NSArray<XAArm64Fixup*>*)fixups
           modInitLength:(NSUInteger)modInitLength
            objcSections:(NSArray<NSDictionary*>*)objcSections
    {
    if (!objcSections)
        objcSections = @[];
    NSMutableData* text = [textIn mutableCopy];
    NSMutableData* data = dataIn ? [dataIn mutableCopy] : [NSMutableData data];
    if (!dataSymbols)
        dataSymbols = [NSSet set];
    if (!exports)
        exports = [NSSet set];
    BOOL hasData = data.length > 0;
    // Bug 066: the tail of __data is the __mod_init_func pointer array. Same
    // bytes, same addresses, same rebases — it is described by its OWN section
    // header so dyld knows to CALL them. Without one it ran nothing, silently.
    NSUInteger miLen = (modInitLength <= data.length) ? modInitLength : 0;
    NSUInteger dOnly = data.length - miLen;
    // Bug 069: the ObjC sections were carved out of the blob by the linker's
    // repartition and sit between the ordinary data and the mod-init tail, so
    // __data ends where the first of them begins.
    for (NSDictionary* osec in objcSections)
        {
        NSUInteger off = [osec[@"off"] unsignedIntegerValue];
        if (off < dOnly)
            dOnly = off;
        }
    BOOL hasModInit = miLen > 0;
    BOOL hasDataSect = dOnly > 0;
    BOOL hasIface = ifaceIn.length > 0;

    // ── 1. imports (unresolved Branch26 → libSystem; plus undefined-symbol
    // POINTER SLOTS in __data, which bind in place — finding #7, same as the
    // executable path) ──
    NSMutableArray<NSString*>* imports = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSNumber*>* importIndex = [NSMutableDictionary dictionary];
    for (XAArm64Fixup* f in fixups)
        {
        // A call (Branch26 → stub), a POINTER SLOT (Pointer64 → in-place bind),
        // AND a GOT-indirect DATA ref (GotPage21/Off12 → a __got slot) all need
        // an import when the symbol is undefined. The GOT case was missing, so a
        // reference to a system data global a bundled C object uses (e.g.
        // ___stack_chk_guard, from -fstack-protector) left its adrp/ldr at zero
        // and the library crashed on first use (mbedtls ctr_drbg_seed).
        if (f.kind != XAArm64FixupBranch26 && f.kind != XAArm64FixupPointer64 && f.kind != XAArm64FixupGotPage21 && f.kind != XAArm64FixupGotPageOff12)
            continue;
        if (symbols[f.symbol])
            continue;
        if (!importIndex[f.symbol])
            {
            importIndex[f.symbol] = @(imports.count);
            [imports addObject:f.symbol];
            }
        }
    NSUInteger nimp = imports.count;
    BOOL hasImp = nimp > 0;
    BOOL hasDataSeg = hasData || hasImp;

    // ── 2. layout — base 0 (dylib), vmaddr == file offset. Segment order is
    // __TEXT(0) [__DATA(1)] [__XTC] __LINKEDIT — note __DATA is segment index 1
    // here (no __PAGEZERO), which the bind/rebase opcodes must reference. ──
    uint64_t textOffset = PAGE; // header/cmd slack
    uint64_t stubsOffset = roundUp(textOffset + text.length, 4);
    uint64_t stubsSize = nimp * STUB_SZ;
    uint64_t textSegEnd = roundUp(stubsOffset + stubsSize, PAGE);
    uint64_t textAddr = textOffset, stubsAddr = stubsOffset;

    uint64_t dataSegFileOff = textSegEnd, dataProgOffset = dataSegFileOff;
    uint64_t gotOffset = roundUp(dataProgOffset + (hasData ? data.length : 0), 8);
    uint64_t gotSize = nimp * GOT_SZ;
    uint64_t dataSegEnd = hasDataSeg ? roundUp(gotOffset + gotSize, PAGE) : textSegEnd;
    uint64_t dataAddr = dataProgOffset, gotAddr = gotOffset;
    uint64_t gotOffInSeg = gotOffset - dataSegFileOff;
    uint8_t dataSegIdx = 1; // __TEXT=0, __DATA=1

    uint64_t xtcSegFileOff = dataSegEnd;
    uint64_t xtcSegEnd = hasIface ? roundUp(xtcSegFileOff + ifaceIn.length, PAGE) : dataSegEnd;
    uint64_t xtcAddr = xtcSegFileOff;

    uint64_t linkeditOff = xtcSegEnd;

    uint64_t (^symAddr)(NSString*) = ^uint64_t(NSString* nm) {
      uint64_t off = symbols[nm].unsignedLongLongValue;
      return [dataSymbols containsObject:nm] ? (dataAddr + off) : (textAddr + off);
    };

    // ── 3. patch fixups in text (identical maths to the exec; base 0) ──
    uint8_t* tb = (uint8_t*)text.mutableBytes;
    uint32_t (^rdw)(uint64_t) = ^uint32_t(uint64_t o) {
      return tb[o] | (tb[o + 1] << 8) | (tb[o + 2] << 16) | ((uint32_t)tb[o + 3] << 24);
    };
    void (^wrw)(uint64_t, uint32_t) = ^(uint64_t o, uint32_t w) {
      tb[o] = (uint8_t)w;
      tb[o + 1] = (uint8_t)(w >> 8);
      tb[o + 2] = (uint8_t)(w >> 16);
      tb[o + 3] = (uint8_t)(w >> 24);
    };
    for (XAArm64Fixup* f in fixups)
        {
        if (f.kind == XAArm64FixupBranch26 && !symbols[f.symbol])
            {
            NSUInteger idx = importIndex[f.symbol].unsignedIntegerValue;
            uint64_t stubAddr = stubsAddr + idx * STUB_SZ;
            int32_t rel = (int32_t)(((int64_t)stubAddr - (int64_t)(textAddr + f.offset)) >> 2);
            wrw(f.offset, (rdw(f.offset) & 0xFC000000u) | ((uint32_t)rel & 0x03FFFFFFu));
            }
        else if (f.kind == XAArm64FixupBranch26 && symbols[f.symbol])
            {
            // A call to a symbol DEFINED in this image. The executable writer has
            // always had this case; the dylib writer did not, because a dylib was
            // always ONE assembled unit and the assembler had already resolved
            // every intra-text branch itself. Merging an object breaks that
            // assumption — the assembler never saw the callee — and the fixup
            // then fell through both arms and stayed ZERO, which encodes `bl .`:
            // a branch to itself. The library loaded, exported the right symbols,
            // and hung the moment the call was made.
            int32_t rel = (int32_t)(((int64_t)symAddr(f.symbol) + f.addend - (int64_t)(textAddr + f.offset)) >> 2);
            wrw(f.offset, (rdw(f.offset) & 0xFC000000u) | ((uint32_t)rel & 0x03FFFFFFu));
            }
        else if (f.kind == XAArm64FixupPage21 && symbols[f.symbol])
            {
            // `+ f.addend` on this and PAGEOFF12 below, as the executable does:
            // a relocation from a merged object carries one, and a single
            // assembled unit never did, which is why it was absent here.
            uint64_t s = symAddr(f.symbol) + (uint64_t)f.addend;
            int64_t d = (int64_t)((s & ~0xFFFull) - ((textAddr + f.offset) & ~0xFFFull));
            int64_t imm = d >> 12;
            uint32_t w = rdw(f.offset) & ~((3u << 29) | (0x7FFFFu << 5));
            wrw(f.offset, w | ((uint32_t)(imm & 3) << 29) | ((uint32_t)((imm >> 2) & 0x7FFFF) << 5));
            }
        else if (f.kind == XAArm64FixupPageOff12 && symbols[f.symbol])
            {
            uint32_t imm12 = (uint32_t)(((symAddr(f.symbol) + (uint64_t)f.addend) & 0xFFF) >> f.scale);
            wrw(f.offset, (rdw(f.offset) & ~(0xFFFu << 10)) | (imm12 << 10));
            }
        // adrp <sym>@GOTPAGE
        else if (f.kind == XAArm64FixupGotPage21 && !symbols[f.symbol])
            {
            uint64_t slot = gotAddr + importIndex[f.symbol].unsignedIntegerValue * GOT_SZ;
            int64_t d = (int64_t)((slot & ~0xFFFull) - ((textAddr + f.offset) & ~0xFFFull));
            int64_t imm = d >> 12;
            uint32_t w = rdw(f.offset) & ~((3u << 29) | (0x7FFFFu << 5));
            wrw(f.offset, w | ((uint32_t)(imm & 3) << 29) | ((uint32_t)((imm >> 2) & 0x7FFFF) << 5));
            }
        // ldr <sym>@GOTPAGEOFF
        else if (f.kind == XAArm64FixupGotPageOff12 && !symbols[f.symbol])
            {
            uint64_t slot = gotAddr + importIndex[f.symbol].unsignedIntegerValue * GOT_SZ;
            wrw(f.offset, (rdw(f.offset) & ~(0xFFFu << 10)) | ((uint32_t)((slot & 0xFFF) >> 3) << 10));
            }
        }
    NSMutableArray<NSNumber*>* rebaseOffs = [NSMutableArray array];
    NSMutableArray<XAArm64Fixup*>* dataBinds = [NSMutableArray array];
    uint8_t* db = (uint8_t*)data.mutableBytes;
    for (XAArm64Fixup* f in fixups)
        {
        if (f.kind != XAArm64FixupPointer64)
            continue;
        if (!symbols[f.symbol])
            {
            if (importIndex[f.symbol])
                [dataBinds addObject:f]; // finding #7
            continue;
            }
        uint64_t s = symAddr(f.symbol);
        for (int i = 0; i < 8; i++)
            db[f.offset + i] = (uint8_t)(s >> (8 * i));
        [rebaseOffs addObject:@(f.offset)];
        }
    BOOL hasRebase = rebaseOffs.count > 0;
    [rebaseOffs sortUsingComparator:^(NSNumber* a, NSNumber* b) {
      return [a compare:b];
    }];
    [dataBinds sortUsingComparator:^(XAArm64Fixup* a, XAArm64Fixup* b) {
      return a.offset < b.offset   ? NSOrderedAscending
             : a.offset > b.offset ? NSOrderedDescending
                                   : NSOrderedSame;
    }];

    NSMutableData* stubs = [NSMutableData data];
    for (NSUInteger i = 0; i < nimp; i++)
        emitStub(stubs, stubsAddr + i * STUB_SZ, gotAddr + i * GOT_SZ);

    // ── 4. __LINKEDIT: rebase | bind | export-trie | nlist | indirect | strtab ──
    NSMutableData* rebase = [NSMutableData data];
    if (hasRebase)
        {
        put8(rebase, REBASE_SET_TYPE_IMM | REBASE_TYPE_POINTER);
        for (NSNumber* o in rebaseOffs)
            {
            put8(rebase, REBASE_SET_SEG_OFF_ULEB | dataSegIdx);
            putULEB(rebase, o.unsignedLongLongValue);
            put8(rebase, REBASE_DO_IMM_TIMES | 1);
            }
        put8(rebase, REBASE_DONE);
        while (rebase.length & 7)
            put8(rebase, 0);
        }
    NSMutableData* bind = [NSMutableData data];
    if (hasImp)
        {
        // FLAT LOOKUP, not libSystem's ordinal: a library's imports may come
        // from ANOTHER xtc library (`_SB$vtbl` — a lib extending / subclassing
        // an imported lib's class), whose LC_LOAD_DYLIB lives on the CLIENT.
        // Binding to ordinal 1 sent dyld to libSystem alone, and the load
        // died with "Symbol not found … Expected in: libSystem". Flat lookup
        // still finds the real libSystem symbols too.
        put8(bind, BIND_SET_DYLIB_SPECIAL_FLAT);
        for (NSUInteger i = 0; i < nimp; i++)
            {
            put8(bind, BIND_SET_SYMBOL_FLAGS | 0);
            const char* nm = imports[i].UTF8String;
            [bind appendBytes:nm length:strlen(nm) + 1];
            put8(bind, BIND_SET_TYPE_IMM | BIND_TYPE_POINTER);
            put8(bind, BIND_SET_SEG_OFF_ULEB | dataSegIdx);
            putULEB(bind, gotOffInSeg + i * GOT_SZ);
            put8(bind, BIND_DO_BIND);
            }
        // Data-slot binds (finding #7) — see the executable path.
        for (XAArm64Fixup* f in dataBinds)
            {
            NSUInteger i = importIndex[f.symbol].unsignedIntegerValue;
            put8(bind, BIND_SET_SYMBOL_FLAGS | 0);
            const char* nm = imports[i].UTF8String;
            [bind appendBytes:nm length:strlen(nm) + 1];
            put8(bind, BIND_SET_TYPE_IMM | BIND_TYPE_POINTER);
            if (f.addend)
                {
                put8(bind, BIND_SET_ADDEND_SLEB);
                putSLEB(bind, f.addend);
                }
            put8(bind, BIND_SET_SEG_OFF_ULEB | dataSegIdx);
            putULEB(bind, f.offset);
            put8(bind, BIND_DO_BIND);
            if (f.addend)
                {
                put8(bind, BIND_SET_ADDEND_SLEB);
                putSLEB(bind, 0);
                }
            }
        put8(bind, BIND_DONE);
        while (bind.length & 7)
            put8(bind, 0);
        }

    // symbol table split: [locals (defined, not exported)][externs (exported)][undefs]
    NSMutableArray<NSString*>*locals = [NSMutableArray array], *externs = [NSMutableArray array];
    // Sorted by OFFSET, ties broken on the NAME. Two symbols can share an
    // offset — a text label at 0 and a data label at 0 always do — and leaving
    // that tie to `allKeys` would make the symbol table's order depend on how
    // the dictionary happened to hash.
    NSArray* defNames = [symbols.allKeys sortedArrayUsingComparator:^(NSString* a, NSString* b) {
      NSComparisonResult r = [symbols[a] compare:symbols[b]];
      return r != NSOrderedSame ? r : [a compare:b];
    }];
    for (NSString* nm in defNames)
        [(([exports containsObject:nm]) ? externs : locals) addObject:nm];
    uint8_t dataSect = (uint8_t)(1 + (hasImp ? 1 : 0) + 1);
    NSMutableData* strtab = [NSMutableData data];
    put8(strtab, 0);
    NSMutableData* nlist = [NSMutableData data];
    void (^emitDef)(NSString*) = ^(NSString* nm) {
      uint32_t strx = (uint32_t)strtab.length;
      const char* c = nm.UTF8String;
      [strtab appendBytes:c length:strlen(c) + 1];
      BOOL inData = [dataSymbols containsObject:nm];
      uint8_t type = XN_SECT | ([exports containsObject:nm] ? XN_EXT : 0);
      put32(nlist, strx);
      put8(nlist, type);
      put8(nlist, inData ? dataSect : 1);
      put8(nlist, 0);
      put8(nlist, 0);
      put64(nlist, symAddr(nm));
    };
    for (NSString* nm in locals)
        emitDef(nm);
    for (NSString* nm in externs)
        emitDef(nm);
    for (NSString* nm in imports)
        {
        uint32_t strx = (uint32_t)strtab.length;
        const char* c = nm.UTF8String;
        [strtab appendBytes:c length:strlen(c) + 1];
        put32(nlist, strx);
        put8(nlist, XN_UNDF | XN_EXT);
        put8(nlist, 0);
        put8(nlist, 0);
        put8(nlist, 0xFE); // n_desc: DYNAMIC_LOOKUP ordinal (flat)
        put64(nlist, 0);
        }
    uint32_t nloc = (uint32_t)locals.count, nexp = (uint32_t)externs.count, nsyms = (uint32_t)(defNames.count + imports.count);
    NSMutableData* indirect = [NSMutableData data];
    for (NSUInteger i = 0; i < nimp; i++)
        put32(indirect, nloc + nexp + (uint32_t)i);

    // export trie: every exported name at its image-relative (base-0) address
    NSMutableArray<NSString*>* expNames = [NSMutableArray array];
    NSMutableArray<NSNumber*>* expAddrs = [NSMutableArray array];
    for (NSString* nm in externs)
        {
        [expNames addObject:nm];
        [expAddrs addObject:@(symAddr(nm))];
        }
    NSMutableData* exportTrie = [buildExportTrie(expNames, expAddrs) mutableCopy];
    BOOL hasExport = exportTrie.length > 0;
    while (exportTrie.length & 7)
        put8(exportTrie, 0); // 8-align so the symtab that follows is aligned

    uint64_t rebaseOff = linkeditOff;
    uint64_t bindOff = rebaseOff + rebase.length;
    uint64_t exportOff = bindOff + bind.length;
    uint64_t symoff = exportOff + exportTrie.length;
    uint64_t indOff = symoff + nlist.length;
    uint64_t stroff = indOff + indirect.length;
    uint64_t strsize = roundUp(strtab.length, 8);
    while (strtab.length < strsize)
        put8(strtab, 0);
    NSString* sigIdent = installName.lastPathComponent ?: @"xtclib";
    uint64_t sigOffset = roundUp(stroff + strsize, 16);
    uint32_t nCodeSlots = (uint32_t)((sigOffset + 4095) / 4096);
    uint32_t sigSize = 12 + 8 + 88 + (uint32_t)(sigIdent.length + 1) + nCodeSlots * 32;
    // The signature must be the LAST bytes of the file — iOS device install
    // and Apple's codesign reject any trailing bytes after it (macOS load
    // tolerates them, which is why this went unnoticed). So the file ends
    // exactly at the signature: __LINKEDIT's FILESIZE is exact, its VMSIZE is
    // page-rounded (in-memory only). (bug 148)
    uint64_t linkeditFilesz = (sigOffset + sigSize) - linkeditOff;
    uint64_t linkeditVmsz = roundUp(linkeditFilesz, PAGE);

    // ── 5. command sizes ──
    const char *dyld = "/usr/lib/dyld", *libSys = "/usr/lib/libSystem.B.dylib";
    const char* instName = installName.UTF8String;
    uint32_t nDataSects = (hasDataSect ? 1 : 0) + (hasModInit ? 1 : 0) + (hasImp ? 1 : 0) + (uint32_t)objcSections.count; // bug 069
    uint32_t szTextSeg = 72 + 80 * (1 + (hasImp ? 1 : 0)), szDataSeg = 72 + 80 * nDataSects, szXtcSeg = 72 + 80, szLink = 72;
    uint32_t szDyldInfo = 48, szDyld = (uint32_t)roundUp(12 + strlen(dyld) + 1, 8);
    uint32_t szId = (uint32_t)roundUp(24 + strlen(instName) + 1, 8), szDylib = (uint32_t)roundUp(24 + strlen(libSys) + 1, 8);
    uint32_t szSym = 24, szDysym = 80, szBuild = 24, szUUID = 24, szCodeSig = 16;
    BOOL hasDyldInfo = hasImp || hasRebase || hasExport;
    uint32_t ncmds = 1 + (hasDataSeg ? 1 : 0) + (hasIface ? 1 : 0) + 1 + (hasDyldInfo ? 1 : 0) + 1 /*dyld*/ + 1 /*id*/ + 1 /*libSystem*/ + 1 /*sym*/ + 1 /*dysym*/ + 1 /*build*/ + 1 /*uuid*/ + 1 /*codesig*/;
    uint32_t sizeofcmds = szTextSeg + (hasDataSeg ? szDataSeg : 0) + (hasIface ? szXtcSeg : 0) + szLink + (hasDyldInfo ? szDyldInfo : 0) + szDyld + szId + szDylib + szSym + szDysym + szBuild + szUUID + szCodeSig;

    // ── 6. emit ──
    NSMutableData* out = [NSMutableData data];
    put32(out, XMH_MAGIC_64);
    put32(out, XCPU_TYPE_ARM64);
    put32(out, 0);
    put32(out, XMH_DYLIB);
    put32(out, ncmds);
    put32(out, sizeofcmds);
    put32(out, XMH_DYLDLINK | XMH_TWOLEVEL);
    put32(out, 0);

    // __TEXT (+ __text [+ __stubs])
    put32(out, XLC_SEGMENT_64);
    put32(out, szTextSeg);
    putFixed(out, "__TEXT", 16);
    put64(out, 0);
    put64(out, textSegEnd);
    put64(out, 0);
    put64(out, textSegEnd);
    put32(out, XVM_READ | XVM_EXEC);
    put32(out, XVM_READ | XVM_EXEC);
    put32(out, hasImp ? 2 : 1);
    put32(out, 0);
    putFixed(out, "__text", 16);
    putFixed(out, "__TEXT", 16);
    put64(out, textAddr);
    put64(out, text.length);
    put32(out, (uint32_t)textOffset);
    put32(out, 2);
    put32(out, 0);
    put32(out, 0);
    put32(out, XS_ATTR_PURE_INSTRUCTIONS | XS_ATTR_SOME_INSTRUCTIONS);
    put32(out, 0);
    put32(out, 0);
    put32(out, 0);
    if (hasImp)
        {
        putFixed(out, "__stubs", 16);
        putFixed(out, "__TEXT", 16);
        put64(out, stubsAddr);
        put64(out, stubsSize);
        put32(out, (uint32_t)stubsOffset);
        put32(out, 2);
        put32(out, 0);
        put32(out, 0);
        put32(out, XS_ATTR_PURE_INSTRUCTIONS | XS_ATTR_SOME_INSTRUCTIONS);
        put32(out, 0);
        put32(out, 0);
        put32(out, 0);
        }
    // __DATA (+ __data + __got)
    if (hasDataSeg)
        {
        uint64_t segSz = dataSegEnd - dataSegFileOff;
        put32(out, XLC_SEGMENT_64);
        put32(out, szDataSeg);
        putFixed(out, "__DATA", 16);
        put64(out, dataSegFileOff);
        put64(out, segSz);
        put64(out, dataSegFileOff);
        put64(out, segSz);
        put32(out, XVM_READ | XVM_WRITE);
        put32(out, XVM_READ | XVM_WRITE);
        put32(out, nDataSects);
        put32(out, 0);
        if (hasDataSect)
            {
            putFixed(out, "__data", 16);
            putFixed(out, "__DATA", 16);
            put64(out, dataAddr);
            put64(out, dOnly);
            put32(out, (uint32_t)dataProgOffset);
            put32(out, 3);
            put32(out, 0);
            put32(out, 0);
            put32(out, XS_REGULAR);
            put32(out, 0);
            put32(out, 0);
            put32(out, 0);
            }
        // Bug 069: the ObjC metadata, each with the segment, type and
        // attributes its input object gave it. The runtime locates
        // __objc_selrefs and friends BY SECTION and rebinds each selref to the
        // canonical selector at load; delivered as anonymous __data they keep
        // their build-time pointers and every message send misses. They are
        // emitted inside __DATA's span because that is where the blob lives —
        // the section's own `segname` is preserved for the runtime to read.
        for (NSDictionary* osec in objcSections)
            {
            putFixed(out, osec[@"name"] ? [osec[@"name"] UTF8String] : "__objc", 16);
            // The segname must name the segment that actually CONTAINS these
            // bytes, which is __DATA — the blob lives there. Carrying the
            // input object's original segname through (`__TEXT` for the
            // cstring pools) produced a header otool reports as "does not
            // match segment": true of the file, and the kind of latent
            // malformedness that is fine until something reads it properly.
            // The runtime keys on the section NAME for the __DATA metadata it
            // scans; the __TEXT-origin pools (__objc_methname and friends) are
            // only ever reached through pointers, never looked up by segment.
            putFixed(out, "__DATA", 16);
            NSUInteger ooff = [osec[@"off"] unsignedIntegerValue];
            NSUInteger osz = [osec[@"size"] unsignedIntegerValue];
            put64(out, dataAddr + ooff);
            put64(out, osz);
            put32(out, (uint32_t)(dataProgOffset + ooff));
            put32(out, 3);
            put32(out, 0);
            put32(out, 0);
            put32(out, [osec[@"flags"] unsignedIntValue]);
            put32(out, 0);
            put32(out, 0);
            put32(out, 0);
            }
        // Bug 066: a LIBRARY's load-time constructors. This is the half that
        // `__xtc_run_modinit` could never reach — nothing can call a library's
        // copy — so the section is the only way they run at all.
        if (hasModInit)
            {
            putFixed(out, "__mod_init_func", 16);
            putFixed(out, "__DATA", 16);
            put64(out, dataAddr + dOnly);
            put64(out, miLen);
            put32(out, (uint32_t)(dataProgOffset + dOnly));
            put32(out, 3);
            put32(out, 0);
            put32(out, 0);
            put32(out, XS_MOD_INIT_FUNC_POINTERS);
            put32(out, 0);
            put32(out, 0);
            put32(out, 0);
            }
        if (hasImp)
            {
            putFixed(out, "__got", 16);
            putFixed(out, "__DATA", 16);
            put64(out, gotAddr);
            put64(out, gotSize);
            put32(out, (uint32_t)gotOffset);
            put32(out, 3);
            put32(out, 0);
            put32(out, 0);
            put32(out, XS_NON_LAZY_SYMBOL_POINTERS);
            put32(out, 0);
            put32(out, 0);
            put32(out, 0);
            }
        }
    // __XTC (+ __iface) — the module-interface metadata, read-only data
    if (hasIface)
        {
        uint64_t segSz = xtcSegEnd - xtcSegFileOff;
        put32(out, XLC_SEGMENT_64);
        put32(out, szXtcSeg);
        putFixed(out, "__XTC", 16);
        put64(out, xtcAddr);
        put64(out, segSz);
        put64(out, xtcSegFileOff);
        put64(out, segSz);
        put32(out, XVM_READ);
        put32(out, XVM_READ);
        put32(out, 1);
        put32(out, 0);
        putFixed(out, "__iface", 16);
        putFixed(out, "__XTC", 16);
        put64(out, xtcAddr);
        put64(out, ifaceIn.length);
        put32(out, (uint32_t)xtcSegFileOff);
        put32(out, 0);
        put32(out, 0);
        put32(out, 0);
        put32(out, XS_REGULAR);
        put32(out, 0);
        put32(out, 0);
        put32(out, 0);
        }
    // __LINKEDIT
    put32(out, XLC_SEGMENT_64);
    put32(out, szLink);
    putFixed(out, "__LINKEDIT", 16);
    put64(out, linkeditOff);
    put64(out, linkeditVmsz);
    put64(out, linkeditOff);
    put64(out, linkeditFilesz);
    put32(out, XVM_READ);
    put32(out, XVM_READ);
    put32(out, 0);
    put32(out, 0);
    // LC_DYLD_INFO_ONLY
    if (hasDyldInfo)
        {
        put32(out, XLC_DYLD_INFO_ONLY);
        put32(out, szDyldInfo);
        put32(out, (uint32_t)(hasRebase ? rebaseOff : 0));
        put32(out, (uint32_t)rebase.length);
        put32(out, (uint32_t)(hasImp ? bindOff : 0));
        put32(out, (uint32_t)bind.length);
        put32(out, 0);
        put32(out, 0); // weak bind
        put32(out, 0);
        put32(out, 0); // lazy bind
        put32(out, (uint32_t)(hasExport ? exportOff : 0));
        put32(out, (uint32_t)exportTrie.length);
        }
    // LC_LOAD_DYLINKER
    put32(out, XLC_LOAD_DYLINKER);
    put32(out, szDyld);
    put32(out, 12);
    putFixed(out, dyld, (int)(szDyld - 12));
    // LC_ID_DYLIB (install name)
    put32(out, XLC_ID_DYLIB);
    put32(out, szId);
    put32(out, 24);
    put32(out, 1);
    put32(out, 0x10000);
    put32(out, 0x10000);
    putFixed(out, instName, (int)(szId - 24));
    // LC_LOAD_DYLIB libSystem
    put32(out, XLC_LOAD_DYLIB);
    put32(out, szDylib);
    put32(out, 24);
    put32(out, 2);
    put32(out, 0x510000);
    put32(out, 0x10000);
    putFixed(out, libSys, (int)(szDylib - 24));
    // LC_SYMTAB
    put32(out, XLC_SYMTAB);
    put32(out, szSym);
    put32(out, (uint32_t)symoff);
    put32(out, nsyms);
    put32(out, (uint32_t)stroff);
    put32(out, (uint32_t)strtab.length);
    // LC_DYSYMTAB
    put32(out, XLC_DYSYMTAB);
    put32(out, szDysym);
    put32(out, 0);
    put32(out, nloc); // ilocalsym,nlocalsym
    put32(out, nloc);
    put32(out, nexp); // iextdefsym,nextdefsym
    put32(out, nloc + nexp);
    put32(out, (uint32_t)nimp); // iundefsym,nundefsym
    put32(out, 0);
    put32(out, 0); // toc
    put32(out, 0);
    put32(out, 0); // modtab
    put32(out, 0);
    put32(out, 0); // extrefsym
    put32(out, (uint32_t)(hasImp ? indOff : 0));
    put32(out, (uint32_t)nimp);
    put32(out, 0);
    put32(out, 0); // extrel
    put32(out, 0);
    put32(out, 0); // locrel
    // LC_BUILD_VERSION
    put32(out, XLC_BUILD_VERSION);
    put32(out, szBuild);
    put32(out, sPlatformId);
    put32(out, sPlatformMinos);
    put32(out, sPlatformSdk);
    put32(out, 0);
    // LC_UUID
    put32(out, XLC_UUID);
    put32(out, szUUID);
    for (int i = 0; i < 16; i++)
        put8(out, 0);
    // LC_CODE_SIGNATURE
    put32(out, XLC_CODE_SIGNATURE);
    put32(out, szCodeSig);
    put32(out, (uint32_t)sigOffset);
    put32(out, sigSize);

    NSAssert(out.length == 32 + sizeofcmds, @"dylib cmds %lu != %u", (unsigned long)out.length, 32 + sizeofcmds);

    // ── 7. file body ──
    while (out.length < textOffset)
        put8(out, 0);
    [out appendData:text];
    while (out.length < stubsOffset)
        put8(out, 0);
    [out appendData:stubs];
    if (hasData)
        {
        while (out.length < dataProgOffset)
            put8(out, 0);
        [out appendData:data];
        }
    if (hasImp)
        {
        while (out.length < gotOffset)
            put8(out, 0);
        for (NSUInteger i = 0; i < gotSize; i++)
            put8(out, 0);
        }
    if (hasIface)
        {
        while (out.length < xtcSegFileOff)
            put8(out, 0);
        [out appendData:ifaceIn];
        }
    while (out.length < linkeditOff)
        put8(out, 0);
    [out appendData:rebase];
    [out appendData:bind];
    [out appendData:exportTrie];
    [out appendData:nlist];
    [out appendData:indirect];
    [out appendData:strtab];
    while (out.length < sigOffset)
        put8(out, 0);
    NSData* sig = buildAdhocSignature(out.bytes, sigOffset, sigIdent, textSegEnd);
    [out appendData:sig];
    while (out.length < linkeditOff + linkeditFilesz)
        put8(out, 0);
    return out;
    }
@end
