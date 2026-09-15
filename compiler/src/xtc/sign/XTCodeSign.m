//
//  XTCodeSign.m — see XTCodeSign.h.
//

#import "XTCodeSign.h"
#import "XTCrypto.h"
#import "XTCms.h"
#import "XTDer.h"
#import "XTDerReader.h"

#define PAGE       0x4000ull     // __LINKEDIT vm/file alignment (arm64)
#define CS_PAGE    4096          // code-signature hash page

// Blob magics
#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0
#define CSMAGIC_CODEDIRECTORY      0xfade0c02
#define CSMAGIC_REQUIREMENTS       0xfade0c01
#define CSMAGIC_ENTITLEMENTS       0xfade7171
#define CSMAGIC_DER_ENTITLEMENTS   0xfade7172
// Slot indices
#define CSSLOT_CODEDIRECTORY       0
#define CSSLOT_INFOSLOT            1   // Info.plist hash (bundle mode)
#define CSSLOT_REQUIREMENTS        2
#define CSSLOT_RESOURCEDIR         3   // _CodeSignature/CodeResources hash (bundle mode)
#define CSSLOT_ENTITLEMENTS        5
#define CSSLOT_DER_ENTITLEMENTS    7
#define CSSLOT_SIGNATURESLOT       0x10000

static void put32be(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = {(uint8_t)(v>>24),(uint8_t)(v>>16),(uint8_t)(v>>8),(uint8_t)v};
    [d appendBytes:b length:4];
}
static void put64be(NSMutableData *d, uint64_t v) {
    put32be(d, (uint32_t)(v>>32)); put32be(d, (uint32_t)v);
}
static uint32_t rd32le(const uint8_t *p) { return p[0]|(p[1]<<8)|(p[2]<<16)|((uint32_t)p[3]<<24); }
static void wr32le(uint8_t *p, uint32_t v) { p[0]=(uint8_t)v;p[1]=(uint8_t)(v>>8);p[2]=(uint8_t)(v>>16);p[3]=(uint8_t)(v>>24); }
static void wr64le(uint8_t *p, uint64_t v) { wr32le(p,(uint32_t)v); wr32le(p+4,(uint32_t)(v>>32)); }
static uint64_t rd64le(const uint8_t *p) { return (uint64_t)rd32le(p) | ((uint64_t)rd32le(p+4)<<32); }
static uint64_t roundUp(uint64_t v, uint64_t a) { return (v+a-1) & ~(a-1); }

// The Team ID is the leaf certificate subject's organizationalUnit (OID
// 2.5.4.11) — Apple puts the 10-char team identifier there. The CodeDirectory
// carries it (teamOffset), and device/Store provisioning matches on it.
static NSString *teamIdFromCert(NSData *certDer) {
    XTDerReader *top = [[XTDerReader alloc] initWithData:certDer]; uint8_t t;
    XTDerReader *cert = [top readConstructed:&t]; if (!cert) return nil;
    XTDerReader *tbs = [cert readConstructed:&t]; if (!tbs) return nil;
    uint8_t vt; if ([tbs peekNextTag:&vt] && vt == 0xA0) (void)[tbs readElement];  // version
    (void)[tbs readTLV:&t];      // serialNumber
    (void)[tbs readElement];     // signatureAlg
    (void)[tbs readElement];     // issuer
    (void)[tbs readElement];     // validity
    XTDerReader *subject = [tbs readConstructed:&t];  // subject Name (SEQ of RDNs)
    if (!subject) return nil;
    const uint8_t ou[] = {0x55, 0x04, 0x0b};          // 2.5.4.11
    while (!subject.atEnd) {
        XTDerReader *rdn = [subject readConstructed:&t]; if (!rdn) break;   // SET
        while (!rdn.atEnd) {
            XTDerReader *atv = [rdn readConstructed:&t]; if (!atv) break;   // SEQ{OID,value}
            NSData *oid = [atv readTLV:&t];
            NSData *val = [atv readTLV:&t];
            if (oid.length == 3 && memcmp(oid.bytes, ou, 3) == 0)
                return [[NSString alloc] initWithData:val encoding:NSUTF8StringEncoding];
        }
    }
    return nil;
}

// A wrapped blob: magic, total length, body.
static NSData *wrapBlob(uint32_t magic, NSData *body) {
    NSMutableData *d = [NSMutableData data];
    put32be(d, magic); put32be(d, (uint32_t)(8 + body.length));
    [d appendData:body];
    return d;
}

@implementation XTCodeSign

// Build a CodeDirectory (v0x20400). `special` maps slot index → 32-byte hash
// (present slots only); `codeHashes` is the concatenated page hashes.
+ (NSData *)codeDirectoryForIdentifier:(NSString *)ident
                             codeLimit:(uint32_t)codeLimit
                            nCodeSlots:(uint32_t)nCodeSlots
                          execSegLimit:(uint64_t)execSegLimit
                               special:(NSDictionary<NSNumber *, NSData *> *)special
                            codeHashes:(NSData *)codeHashes
                                 flags:(uint32_t)flags
                            teamId:(nullable NSString *)teamId {
    const uint32_t hashSize = 32;
    const char *id = ident.UTF8String; uint32_t idLen = (uint32_t)strlen(id);
    const char *team = teamId.length ? teamId.UTF8String : NULL;
    uint32_t teamLen = team ? (uint32_t)strlen(team) : 0;

    uint32_t nSpecial = 0;
    for (NSNumber *k in special) nSpecial = MAX(nSpecial, (uint32_t)k.intValue);

    uint32_t hdr = 88;
    uint32_t identOffset = hdr;
    uint32_t teamOffset = team ? (identOffset + idLen + 1) : 0;
    uint32_t afterStrings = identOffset + idLen + 1 + (team ? teamLen + 1 : 0);
    uint32_t hashOffset = afterStrings + nSpecial * hashSize;   // → code slot 0
    uint32_t cdLength = hashOffset + nCodeSlots * hashSize;

    NSMutableData *cd = [NSMutableData data];
    put32be(cd, CSMAGIC_CODEDIRECTORY);
    put32be(cd, cdLength);
    put32be(cd, 0x20400);                 // version
    put32be(cd, flags);
    put32be(cd, hashOffset);
    put32be(cd, identOffset);
    put32be(cd, nSpecial);
    put32be(cd, nCodeSlots);
    put32be(cd, codeLimit);
    uint8_t b4[4] = {hashSize, 2 /*SHA256*/, 0 /*platform*/, 12 /*log2(4096)*/};
    [cd appendBytes:b4 length:4];
    put32be(cd, 0);                        // spare2
    put32be(cd, 0);                        // scatterOffset
    put32be(cd, teamOffset);               // teamOffset
    put32be(cd, 0);                        // spare3
    put64be(cd, 0);                        // codeLimit64
    put64be(cd, 0);                        // execSegBase
    put64be(cd, execSegLimit);
    put64be(cd, 0x1);                      // execSegFlags = MAIN_BINARY
    [cd appendBytes:id length:idLen + 1];
    if (team) [cd appendBytes:team length:teamLen + 1];
    // Special slots, in memory order slot N .. slot 1 (reverse); absent = zero.
    uint8_t zero[32] = {0};
    for (uint32_t i = nSpecial; i >= 1; i--) {
        NSData *h = special[@(i)];
        [cd appendBytes:(h ? h.bytes : zero) length:32];
        if (i == 1) break;   // uint32 underflow guard
    }
    [cd appendData:codeHashes];
    NSAssert(cd.length == cdLength, @"CD length %lu != %u", (unsigned long)cd.length, cdLength);
    return cd;
}

+ (NSData *)superBlobFrom:(NSArray<NSDictionary *> *)blobs {
    // Each entry: @{ @"slot": @(n), @"data": blobData }. Index then bodies.
    uint32_t count = (uint32_t)blobs.count;
    uint32_t headerAndIndex = 12 + count * 8;   // magic+length+count, then index
    uint32_t total = headerAndIndex;
    for (NSDictionary *b in blobs) total += (uint32_t)[b[@"data"] length];

    NSMutableData *sb = [NSMutableData data];
    put32be(sb, CSMAGIC_EMBEDDED_SIGNATURE);
    put32be(sb, total);
    put32be(sb, count);
    uint32_t off = headerAndIndex;
    for (NSDictionary *b in blobs) {
        put32be(sb, (uint32_t)[b[@"slot"] intValue]);
        put32be(sb, off);
        off += (uint32_t)[b[@"data"] length];
    }
    for (NSDictionary *b in blobs) [sb appendData:b[@"data"]];
    NSAssert(sb.length == total, @"superblob %lu != %u", (unsigned long)sb.length, total);
    return sb;
}

// DER-encode an entitlements plist the way codesign does for CD slot 7:
//   [APPLICATION 16] { INTEGER version=1, [CONTEXT 16] { SEQUENCE{key,val}... } }
// keys sorted ascending; string -> UTF8String, bool -> BOOLEAN. Returns nil if a
// value is a type this minimal encoder does not handle (so it can't miscompile).
+ (nullable NSData *)derEntitlementValue:(id)v {
    // string -> UTF8String, bool -> BOOLEAN, array -> SEQUENCE of its elements
    // (order preserved). A dict/data/integer value is not yet supported (nil).
    if ([v isKindOfClass:[NSString class]]) return [XTDer utf8String:v];
    if ([v isKindOfClass:[NSNumber class]]) return [XTDer boolean:[v boolValue]];
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableData *els = [NSMutableData data];
        for (id e in v) {
            NSData *ed = [self derEntitlementValue:e];
            if (!ed) return nil;
            [els appendData:ed];
        }
        return [XTDer tlv:0x30 content:els];   // SEQUENCE
    }
    return nil;
}

+ (nullable NSData *)derEntitlementsFromXml:(NSData *)xml {
    NSDictionary *dict = [NSPropertyListSerialization propertyListWithData:xml
                              options:0 format:NULL error:NULL];
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *keys = [dict.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSData *> *pairs = [NSMutableArray array];
    for (NSString *k in keys) {
        NSData *vd = [self derEntitlementValue:dict[k]];
        if (!vd) return nil;
        NSMutableData *kv = [NSMutableData data];
        [kv appendData:[XTDer utf8String:k]];
        [kv appendData:vd];
        [pairs addObject:[XTDer tlv:0x30 content:kv]];   // SEQUENCE
    }
    NSMutableData *pairsData = [NSMutableData data];
    for (NSData *p in pairs) [pairsData appendData:p];
    NSData *ctx = [XTDer tlv:0xb0 content:pairsData];     // [CONTEXT 16] the dict
    NSMutableData *inner = [NSMutableData data];
    [inner appendData:[XTDer integerFromU64:1]];          // version = 1
    [inner appendData:ctx];
    return [XTDer tlv:0x70 content:inner];                // [APPLICATION 16]
}

+ (nullable NSData *)resign:(NSData *)machO
                 identifier:(NSString *)identifier
                leafCertDer:(NSData *)leafCertDer
                   chainDer:(NSArray<NSData *> *)chainDer
                    modulus:(NSData *)modulus
            privateExponent:(NSData *)privateExponent
            entitlementsXml:(nullable NSData *)entitlementsXml
                   infoPlist:(nullable NSData *)infoPlist
              codeResources:(nullable NSData *)codeResources
                signingTime:(NSString *)signingTime
                      error:(NSString *_Nullable*_Nullable)error {
    #define FAIL(msg) do { if (error) *error = msg; return nil; } while (0)
    const uint8_t *base = machO.bytes; NSUInteger flen = machO.length;
    if (flen < 32) FAIL(@"file too small");
    uint32_t magic = rd32le(base);
    if (magic != 0xFEEDFACF) FAIL(@"not a 64-bit little-endian Mach-O");
    uint32_t ncmds = rd32le(base + 16);

    // Walk load commands for __TEXT filesize, __LINKEDIT, LC_CODE_SIGNATURE.
    uint64_t textFilesize = 0;
    NSUInteger linkeditCmdOff = 0, linkeditFileoff = 0;
    NSUInteger csCmdOff = 0; uint32_t csDataoff = 0;
    NSUInteger p = 32;
    for (uint32_t i = 0; i < ncmds && p + 8 <= flen; i++) {
        uint32_t cmd = rd32le(base + p), csize = rd32le(base + p + 4);
        if (csize < 8 || p + csize > flen) FAIL(@"bad load command");
        if (cmd == 0x19) {                                  // LC_SEGMENT_64
            const char *seg = (const char *)(base + p + 8);
            if (strncmp(seg, "__TEXT", 16) == 0)      textFilesize = rd64le(base + p + 48);
            else if (strncmp(seg, "__LINKEDIT", 16) == 0) {
                linkeditCmdOff = p; linkeditFileoff = rd64le(base + p + 40);
            }
        } else if (cmd == 0x1d) {                           // LC_CODE_SIGNATURE
            csCmdOff = p; csDataoff = rd32le(base + p + 8);
        }
        p += csize;
    }
    if (!linkeditCmdOff) FAIL(@"no __LINKEDIT");
    if (!csCmdOff)       FAIL(@"no LC_CODE_SIGNATURE (binary is not even ad-hoc signed)");

    uint32_t codeLimit = csDataoff;                         // sig starts here
    if (codeLimit == 0 || codeLimit > flen) FAIL(@"bad code-signature offset");
    uint32_t nCodeSlots = (codeLimit + CS_PAGE - 1) / CS_PAGE;
    NSString *teamId = teamIdFromCert(leafCertDer);        // nil for a self-signed cert

    // ── special-slot blobs (requirements always; entitlements if given) ──
    NSData *reqBlob = wrapBlob(CSMAGIC_REQUIREMENTS,
        ({ NSMutableData *m = [NSMutableData data]; put32be(m, 0); m; }));  // empty set (count 0)
    NSMutableDictionary<NSNumber *, NSData *> *specialBlobs = [NSMutableDictionary dictionary];
    specialBlobs[@(CSSLOT_REQUIREMENTS)] = reqBlob;
    if (entitlementsXml) {
        specialBlobs[@(CSSLOT_ENTITLEMENTS)] = wrapBlob(CSMAGIC_ENTITLEMENTS, entitlementsXml);
        // The DER-entitlements blob (slot 7): iOS installd REQUIRES it (macOS
        // codesign --verify does not). Without it a device rejects the app with
        // 0xe8008029 "code signature version no longer supported".
        NSData *derEnt = [self derEntitlementsFromXml:entitlementsXml];
        if (derEnt)
            specialBlobs[@(CSSLOT_DER_ENTITLEMENTS)] = wrapBlob(CSMAGIC_DER_ENTITLEMENTS, derEnt);
    }
    NSMutableDictionary<NSNumber *, NSData *> *specialHashes = [NSMutableDictionary dictionary];
    for (NSNumber *slot in specialBlobs)
        specialHashes[slot] = [XTCrypto sha256:specialBlobs[slot]];
    // Bundle-mode hash-only slots: the CD seals the Info.plist (slot 1) and the
    // CodeResources file (slot 3). They have NO SuperBlob index entry — only a
    // special-slot hash — so they go in specialHashes but not specialBlobs/list.
    if (infoPlist)      specialHashes[@(CSSLOT_INFOSLOT)]    = [XTCrypto sha256:infoPlist];
    if (codeResources)  specialHashes[@(CSSLOT_RESOURCEDIR)] = [XTCrypto sha256:codeResources];

    // ── size the signature: build a placeholder CMS to learn its exact length ──
    NSData *zeroHash = [NSMutableData dataWithLength:32];
    NSData *cmsProbe = [XTCms signedDataForCodeDirectorySha256:zeroHash
                             signerCertDer:leafCertDer chainDer:chainDer
                             keyModulus:modulus keyPrivateExponent:privateExponent
                             signingTime:signingTime];
    if (!cmsProbe) FAIL(@"CMS build failed (bad cert/key?)");
    NSData *cmsProbeBlob = wrapBlob(0xfade0b01, cmsProbe);

    // Build a placeholder CD (zero code hashes) to learn its exact length.
    NSData *zeroCodeHashes = [NSMutableData dataWithLength:nCodeSlots * 32];
    NSData *cdProbe = [self codeDirectoryForIdentifier:identifier codeLimit:codeLimit
                            nCodeSlots:nCodeSlots execSegLimit:textFilesize
                            special:specialHashes codeHashes:zeroCodeHashes flags:0 teamId:teamId];

    NSMutableArray<NSDictionary *> *probeList = [NSMutableArray array];
    [probeList addObject:@{@"slot": @(CSSLOT_CODEDIRECTORY), @"data": cdProbe}];
    [probeList addObject:@{@"slot": @(CSSLOT_REQUIREMENTS), @"data": reqBlob}];
    if (entitlementsXml)
        [probeList addObject:@{@"slot": @(CSSLOT_ENTITLEMENTS), @"data": specialBlobs[@(CSSLOT_ENTITLEMENTS)]}];
    if (specialBlobs[@(CSSLOT_DER_ENTITLEMENTS)])
        [probeList addObject:@{@"slot": @(CSSLOT_DER_ENTITLEMENTS), @"data": specialBlobs[@(CSSLOT_DER_ENTITLEMENTS)]}];
    [probeList addObject:@{@"slot": @(CSSLOT_SIGNATURESLOT), @"data": cmsProbeBlob}];
    uint32_t sigSize = (uint32_t)[self superBlobFrom:probeList].length;

    // ── patch the header, then hash the pages over the finalized bytes ──
    // The signature is the file's LAST bytes: exact filesize (no trailing
    // padding — iOS/codesign reject it), page-rounded vmsize (bug 148).
    uint64_t newLinkeditFilesz = (codeLimit + sigSize) - linkeditFileoff;
    uint64_t newLinkeditVmsz   = roundUp(newLinkeditFilesz, PAGE);
    NSMutableData *work = [NSMutableData dataWithBytes:base length:codeLimit];
    uint8_t *w = work.mutableBytes;
    wr32le(w + csCmdOff + 12, sigSize);                    // LC_CODE_SIGNATURE.datasize
    wr64le(w + linkeditCmdOff + 32, newLinkeditVmsz);      // __LINKEDIT.vmsize
    wr64le(w + linkeditCmdOff + 48, newLinkeditFilesz);    // __LINKEDIT.filesize

    NSMutableData *codeHashes = [NSMutableData data];
    for (uint32_t i = 0; i < nCodeSlots; i++) {
        uint64_t off = (uint64_t)i * CS_PAGE, len = codeLimit - off;
        if (len > CS_PAGE) len = CS_PAGE;
        [codeHashes appendData:[XTCrypto sha256:[NSData dataWithBytesNoCopy:(void *)(w + off)
                                                                    length:(NSUInteger)len
                                                              freeWhenDone:NO]]];
    }

    // ── real CD, real CMS over its hash, final SuperBlob ──
    NSData *cd = [self codeDirectoryForIdentifier:identifier codeLimit:codeLimit
                       nCodeSlots:nCodeSlots execSegLimit:textFilesize
                       special:specialHashes codeHashes:codeHashes flags:0 teamId:teamId];
    NSData *cdHash = [XTCrypto sha256:cd];
    NSData *cms = [XTCms signedDataForCodeDirectorySha256:cdHash
                        signerCertDer:leafCertDer chainDer:chainDer
                        keyModulus:modulus keyPrivateExponent:privateExponent
                        signingTime:signingTime];
    if (!cms) FAIL(@"CMS build failed");
    NSData *cmsBlob = wrapBlob(0xfade0b01, cms);

    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    [list addObject:@{@"slot": @(CSSLOT_CODEDIRECTORY), @"data": cd}];
    [list addObject:@{@"slot": @(CSSLOT_REQUIREMENTS), @"data": reqBlob}];
    if (entitlementsXml)
        [list addObject:@{@"slot": @(CSSLOT_ENTITLEMENTS), @"data": specialBlobs[@(CSSLOT_ENTITLEMENTS)]}];
    if (specialBlobs[@(CSSLOT_DER_ENTITLEMENTS)])
        [list addObject:@{@"slot": @(CSSLOT_DER_ENTITLEMENTS), @"data": specialBlobs[@(CSSLOT_DER_ENTITLEMENTS)]}];
    [list addObject:@{@"slot": @(CSSLOT_SIGNATURESLOT), @"data": cmsBlob}];
    NSData *superBlob = [self superBlobFrom:list];
    if (superBlob.length != sigSize)
        FAIL(([NSString stringWithFormat:@"sig size drift %lu != %u",
               (unsigned long)superBlob.length, sigSize]));

    // ── assemble: patched [0,codeLimit) + signature + zero pad to segment end ──
    NSMutableData *out = [NSMutableData dataWithData:work];
    [out appendData:superBlob];
    // No trailing pad: the file ends at the signature (148).
    return out;
    #undef FAIL
}

@end
