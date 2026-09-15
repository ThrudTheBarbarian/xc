#import "XTApkSign.h"
#import "XTCrypto.h"
#import "XTDer.h"

static void p32le(NSMutableData* d, uint32_t v)
    {
    for (int i = 0; i < 4; i++)
        {
        uint8_t b = (uint8_t)(v >> (8 * i));
        [d appendBytes:&b length:1];
        }
    }
static void p64le(NSMutableData* d, uint64_t v)
    {
    for (int i = 0; i < 8; i++)
        {
        uint8_t b = (uint8_t)(v >> (8 * i));
        [d appendBytes:&b length:1];
        }
    }
static uint32_t r32le(const uint8_t* p)
    {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    }

// Every list in the v2 format is uint32-length-prefixed, so this is most of it.
static NSData* lenPrefixed(NSData* d)
    {
    NSMutableData* o = [NSMutableData data];
    p32le(o, (uint32_t)d.length);
    [o appendData:d];
    return o;
    }

static NSError* apkErr(NSString* m)
    {
    return [NSError errorWithDomain:@"XTApkSign"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : m}];
    }

@implementation XTApkSign

// SubjectPublicKeyInfo { rsaEncryption, BIT STRING { RSAPublicKey } }
static NSData* spkiFor(NSData* n, NSData* e)
    {
    NSData* rsaPub = [XTDer sequence:@[ [XTDer integer:n], [XTDer integer:e] ]];
    NSData* algo = [XTDer sequence:@[ [XTDer oid:@"1.2.840.113549.1.1.1"], [XTDer null] ]];
    return [XTDer sequence:@[ algo, [XTDer bitString:rsaPub unusedBits:0] ]];
    }

+ (nullable NSData*)selfSignedCertificateWithModulus:(NSData*)n
                                      publicExponent:(NSData*)e
                                     privateExponent:(NSData*)d
                                          commonName:(NSString*)cn
                                               error:(NSError**)error
    {
    // sha256WithRSAEncryption, used both inside the TBS and alongside it — a
    // verifier checks the two agree, so they are built from one value.
    NSData* sigAlgo = [XTDer sequence:@[ [XTDer oid:@"1.2.840.113549.1.1.11"], [XTDer null] ]];
    NSData* name = [XTDer sequence:@[
        [XTDer setOf:@[ [XTDer sequence:@[ [XTDer oid:@"2.5.4.3"],
                                           [XTDer utf8String:cn] ]] ]]
    ]];
    // Fixed dates, not "now": two builds of the same input should give the same
    // bytes, and a debug certificate's validity window is not information.
    NSData* validity = [XTDer sequence:@[ [XTDer utcTime:@"200101000000Z"],
                                          [XTDer generalizedTime:@"20990101000000Z"] ]];
    uint8_t serialByte = 1;
    NSData* tbs = [XTDer sequence:@[
        [XTDer explicitTag:0
                   content:[XTDer integerFromU64:2]], // v3
        [XTDer integer:[NSData dataWithBytes:&serialByte length:1]],
        sigAlgo,
        name, // issuer
        validity,
        name, // subject == issuer
        spkiFor(n, e),
    ]];
    NSData* digest = [XTCrypto sha256:tbs];
    NSData* digestInfo = [XTDer sequence:@[
        [XTDer sequence:@[ [XTDer oid:@"2.16.840.1.101.3.4.2.1"], [XTDer null] ]],
        [XTDer octetString:digest],
    ]];
    NSData* sig = [XTCrypto rsaSignPKCS1:digestInfo modulus:n privateExponent:d];
    if (!sig)
        {
        if (error)
            *error = apkErr(@"certificate signature failed");
        return nil;
        }
    return [XTDer sequence:@[ tbs, sigAlgo, [XTDer bitString:sig unusedBits:0] ]];
    }

// The v2 digest of one region: each 1 MB chunk is hashed with a 0xa5 prefix and
// its own length, then the chunk digests are hashed together under 0x5a. The
// prefixes are what stop a chunk boundary being moved without changing the
// result.
#define APK_CHUNK (1024u * 1024u)

static NSUInteger chunkCount(NSUInteger len)
    {
    return (len + APK_CHUNK - 1) / APK_CHUNK;
    }

static void appendChunkDigests(NSMutableData* out, const uint8_t* base, NSUInteger len)
    {
    NSUInteger n = chunkCount(len);
    for (NSUInteger i = 0; i < n; i++)
        {
        NSUInteger off = i * APK_CHUNK;
        NSUInteger sz = MIN((NSUInteger)APK_CHUNK, len - off);
        NSMutableData* pre = [NSMutableData data];
        uint8_t tag = 0xa5;
        [pre appendBytes:&tag length:1];
        p32le(pre, (uint32_t)sz);
        [pre appendBytes:base + off length:sz];
        [out appendData:[XTCrypto sha256:pre]];
        }
    }

+ (nullable NSData*)signedApkFromUnsigned:(NSData*)apk
                                  certDer:(NSData*)certDer
                                  modulus:(NSData*)n
                           publicExponent:(NSData*)e
                          privateExponent:(NSData*)d
                                    error:(NSError**)error
    {
    const uint8_t* b = apk.bytes;
    NSUInteger len = apk.length;
    // Find the end-of-central-directory record. It has a variable-length
    // comment, so it is located by scanning back for its signature — ours
    // writes no comment, but reading it properly costs nothing and means this
    // is not silently wrong the day something else builds the container.
    NSInteger eocdOff = -1;
    for (NSInteger i = (NSInteger)len - 22; i >= 0 && i > (NSInteger)len - 65558; i--)
        {
        if (r32le(b + i) == 0x06054b50)
            {
            eocdOff = i;
            break;
            }
        }
    if (eocdOff < 0)
        {
        if (error)
            *error = apkErr(@"no end-of-central-directory record");
        return nil;
        }
    uint32_t cdSize = r32le(b + eocdOff + 12);
    uint32_t cdOff = r32le(b + eocdOff + 16);
    if ((NSUInteger)cdOff + cdSize > len)
        {
        if (error)
            *error = apkErr(@"central directory out of range");
        return nil;
        }

    // ── the three digested regions ──
    // The EOCD is digested UNMODIFIED: the signing block lands exactly where
    // the central directory starts today, so the field already holds the value
    // the spec asks for (the block's offset). Only the file we finally write
    // gets the field moved past the block.
    NSMutableData* chunks = [NSMutableData data];
    appendChunkDigests(chunks, b, cdOff);
    appendChunkDigests(chunks, b + cdOff, cdSize);
    appendChunkDigests(chunks, b + eocdOff, len - (NSUInteger)eocdOff);
    NSUInteger total = chunkCount(cdOff) + chunkCount(cdSize) + chunkCount(len - (NSUInteger)eocdOff);

    NSMutableData* top = [NSMutableData data];
    uint8_t tag = 0x5a;
    [top appendBytes:&tag length:1];
    p32le(top, (uint32_t)total);
    [top appendData:chunks];
    NSData* apkDigest = [XTCrypto sha256:top];

    // ── signed data ──
    const uint32_t SIG_RSA_PKCS1_SHA256 = 0x0103;
    NSMutableData* digests = [NSMutableData data];
        {
        NSMutableData* one = [NSMutableData data];
        p32le(one, SIG_RSA_PKCS1_SHA256);
        [one appendData:lenPrefixed(apkDigest)];
        [digests appendData:lenPrefixed(one)];
        }
    NSData* certs = lenPrefixed(certDer);
    NSMutableData* signedData = [NSMutableData data];
    [signedData appendData:lenPrefixed(digests)];
    [signedData appendData:lenPrefixed(certs)];
    [signedData appendData:lenPrefixed([NSData data])]; // additional attributes

    // ── the signature over it ──
    NSData* sdDigest = [XTCrypto sha256:signedData];
    NSData* digestInfo = [XTDer sequence:@[
        [XTDer sequence:@[ [XTDer oid:@"2.16.840.1.101.3.4.2.1"], [XTDer null] ]],
        [XTDer octetString:sdDigest],
    ]];
    NSData* sig = [XTCrypto rsaSignPKCS1:digestInfo modulus:n privateExponent:d];
    if (!sig)
        {
        if (error)
            *error = apkErr(@"apk signature failed");
        return nil;
        }

    NSMutableData* signatures = [NSMutableData data];
        {
        NSMutableData* one = [NSMutableData data];
        p32le(one, SIG_RSA_PKCS1_SHA256);
        [one appendData:lenPrefixed(sig)];
        [signatures appendData:lenPrefixed(one)];
        }
    NSMutableData* signer = [NSMutableData data];
    [signer appendData:lenPrefixed(signedData)];
    [signer appendData:lenPrefixed(signatures)];
    [signer appendData:lenPrefixed(spkiFor(n, e))];
    NSData* signers = lenPrefixed(signer);
    NSData* v2Value = lenPrefixed(signers);

    // ── the APK Signing Block ──
    // {u64 size} {pairs} {u64 size} {16-byte magic} — the size appears twice so
    // the block can be found from either end, and it counts everything after
    // the FIRST size field.
    NSMutableData* pairs = [NSMutableData data];
    p64le(pairs, (uint64_t)(4 + v2Value.length)); // id + value
    p32le(pairs, 0x7109871a);                     // the v2 signature block id
    [pairs appendData:v2Value];

    NSMutableData* block = [NSMutableData data];
    uint64_t blockSize = pairs.length + 8 + 16;
    p64le(block, blockSize);
    [block appendData:pairs];
    p64le(block, blockSize);
    [block appendBytes:"APK Sig Block 42" length:16];

    // ── the file ──
    NSMutableData* out = [NSMutableData data];
    [out appendBytes:b length:cdOff];
    [out appendData:block];
    [out appendBytes:b + cdOff length:cdSize];
    NSMutableData* eocd = [[apk subdataWithRange:
                                    NSMakeRange((NSUInteger)eocdOff, len - (NSUInteger)eocdOff)] mutableCopy];
    uint32_t newCdOff = (uint32_t)(cdOff + block.length);
    uint8_t* ep = eocd.mutableBytes;
    for (int i = 0; i < 4; i++)
        ep[16 + i] = (uint8_t)(newCdOff >> (8 * i));
    [out appendData:eocd];
    return out;
    }

@end
