//
//  XTAscApi.m — see XTAscApi.h.
//

#import "XTAscApi.h"
#import "XTHttps.h"
#import "XTDer.h"
#import "XTDerReader.h"
#import "XTCrypto.h"
#import <mbedtls/pk.h>
#import <mbedtls/md.h>
#import <mbedtls/asn1.h>
#import <psa/crypto.h>

static NSString* const ASC_HOST = @"api.appstoreconnect.apple.com";

static NSString* b64url(NSData* d)
    {
    NSString* s = [d base64EncodedStringWithOptions:0];
    s = [s stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    s = [s stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    s = [s stringByReplacingOccurrencesOfString:@"=" withString:@""];
    return s;
    }

@implementation XTAscApi
    {
    NSString *_issuerId, *_keyId, *_p8Path;
    }

- (nullable instancetype)initWithIssuerId:(NSString*)issuerId
                                    keyId:(NSString*)keyId
                                   p8Path:(NSString*)p8Path
                                    error:(NSString* _Nullable* _Nullable)error
    {
    if ((self = [super init]))
        {
        _issuerId = [issuerId copy];
        _keyId = [keyId copy];
        _p8Path = [p8Path copy];
        if (psa_crypto_init() != PSA_SUCCESS)
            {
            if (error)
                *error = @"PSA init failed";
            return nil;
            }
        if (![[NSFileManager defaultManager] fileExistsAtPath:p8Path])
            {
            if (error)
                *error = [NSString stringWithFormat:@"no .p8 at %@", p8Path];
            return nil;
            }
        }
    return self;
    }

// ── ES256 JWT signed by the .p8 ──
- (nullable NSString*)jwt:(NSString* _Nullable* _Nullable)error
    {
    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    if (mbedtls_pk_parse_keyfile(&pk, _p8Path.fileSystemRepresentation, NULL) != 0)
        {
        if (error)
            *error = @"could not parse the .p8 key";
        mbedtls_pk_free(&pk);
        return nil;
        }
    long now = (long)time(NULL);
    NSString* hdr = [NSString stringWithFormat:@"{\"alg\":\"ES256\",\"kid\":\"%@\",\"typ\":\"JWT\"}", _keyId];
    NSString* claims = [NSString stringWithFormat:
                                     @"{\"iss\":\"%@\",\"iat\":%ld,\"exp\":%ld,\"aud\":\"appstoreconnect-v1\"}", _issuerId, now, now + 1200];
    NSString* signing = [NSString stringWithFormat:@"%@.%@",
                                                   b64url([hdr dataUsingEncoding:NSUTF8StringEncoding]),
                                                   b64url([claims dataUsingEncoding:NSUTF8StringEncoding])];
    unsigned char hash[32];
    NSData* si = [signing dataUsingEncoding:NSUTF8StringEncoding];
    mbedtls_md(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), si.bytes, si.length, hash);
    unsigned char der[160];
    size_t derlen = 0;
    int r = mbedtls_pk_sign(&pk, MBEDTLS_MD_SHA256, hash, 32, der, sizeof der, &derlen);
    mbedtls_pk_free(&pk);
    if (r)
        {
        if (error)
            *error = @"ES256 signing failed";
        return nil;
        }
    // DER ECDSA-Sig-Value SEQ{ INTEGER r, INTEGER s } → raw 32+32 (JOSE)
    unsigned char raw[64];
    memset(raw, 0, 64);
    unsigned char *p = der, *end = der + derlen;
    size_t len;
    mbedtls_asn1_get_tag(&p, end, &len, MBEDTLS_ASN1_CONSTRUCTED | MBEDTLS_ASN1_SEQUENCE);
    for (int part = 0; part < 2; part++)
        {
        if (mbedtls_asn1_get_tag(&p, end, &len, MBEDTLS_ASN1_INTEGER) != 0)
            {
            if (error)
                *error = @"bad ECDSA sig";
            return nil;
            }
        unsigned char* ip = p;
        size_t il = len;
        while (il > 0 && *ip == 0)
            {
            ip++;
            il--;
            }
        if (il > 32)
            il = 32;
        memcpy(raw + part * 32 + (32 - il), ip, il);
        p += len;
        }
    return [NSString stringWithFormat:@"%@.%@", signing, b64url([NSData dataWithBytes:raw length:64])];
    }

- (nullable XTHttpsResponse*)call:(NSString*)method path:(NSString*)path
                             body:(nullable NSData*)body
                            error:(NSString* _Nullable* _Nullable)error
    {
    NSString* token = [self jwt:error];
    if (!token)
        return nil;
    NSMutableDictionary* h = [@{@"Authorization" : [@"Bearer " stringByAppendingString:token],
                                @"Accept" : @"application/json"} mutableCopy];
    if (body)
        h[@"Content-Type"] = @"application/json";
    XTHttpsResponse* resp = [XTHttps request:method host:ASC_HOST path:path headers:h body:body];
    if (resp.status < 0)
        {
        if (error)
            *error = resp.error;
        return nil;
        }
    return resp;
    }

- (nullable NSData*)listCertificates:(NSString* _Nullable* _Nullable)error
    {
    XTHttpsResponse* r = [self call:@"GET" path:@"/v1/certificates?limit=200" body:nil error:error];
    if (!r)
        return nil;
    if (r.status != 200)
        {
        if (error)
            *error = [NSString stringWithFormat:@"HTTP %ld: %@",
                                                (long)r.status, [[NSString alloc] initWithData:r.body encoding:NSUTF8StringEncoding]];
        return nil;
        }
    return r.body;
    }
- (BOOL)revokeCertificate:(NSString*)certId error:(NSString* _Nullable* _Nullable)error
    {
    NSString* path = [@"/v1/certificates/" stringByAppendingString:certId];
    XTHttpsResponse* r = [self call:@"DELETE" path:path body:nil error:error];
    if (!r)
        return NO;
    if (r.status != 204 && r.status != 200)
        {
        if (error)
            *error = [NSString stringWithFormat:@"revoke HTTP %ld: %@", (long)r.status,
                                                [[NSString alloc] initWithData:r.body
                                                                      encoding:NSUTF8StringEncoding]];
        return NO;
        }
    return YES;
    }

- (nullable NSData*)listProfiles:(NSString* _Nullable* _Nullable)error
    {
    XTHttpsResponse* r = [self call:@"GET" path:@"/v1/profiles?limit=200" body:nil error:error];
    if (!r)
        return nil;
    if (r.status != 200)
        {
        if (error)
            *error = [NSString stringWithFormat:@"HTTP %ld: %@",
                                                (long)r.status, [[NSString alloc] initWithData:r.body encoding:NSUTF8StringEncoding]];
        return nil;
        }
    return r.body;
    }

// ── RSA-2048 keygen (PSA) + in-house CSR ──
- (nullable NSString*)generateKeypairAndCSRWithCommonName:(NSString*)cn
                                              keyPkcs1Der:(NSData* _Nullable* _Nonnull)keyOut
                                                    error:(NSString* _Nullable* _Nullable)error
    {
    psa_key_attributes_t attr = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attr, PSA_KEY_TYPE_RSA_KEY_PAIR);
    psa_set_key_bits(&attr, 2048);
    psa_set_key_usage_flags(&attr, PSA_KEY_USAGE_SIGN_HASH | PSA_KEY_USAGE_EXPORT);
    psa_set_key_algorithm(&attr, PSA_ALG_RSA_PKCS1V15_SIGN(PSA_ALG_SHA_256));
    psa_key_id_t kid = 0;
    if (psa_generate_key(&attr, &kid) != PSA_SUCCESS)
        {
        if (error)
            *error = @"RSA keygen failed";
        return nil;
        }
    unsigned char kbuf[2048];
    size_t klen = 0;
    psa_status_t es = psa_export_key(kid, kbuf, sizeof kbuf, &klen);
    psa_destroy_key(kid);
    if (es != PSA_SUCCESS)
        {
        if (error)
            *error = @"key export failed";
        return nil;
        }
    NSData* keyPkcs1 = [NSData dataWithBytes:kbuf length:klen]; // PKCS#1 RSAPrivateKey
    *keyOut = keyPkcs1;

    // Parse n, e, d out of PKCS#1 { version, n, e, d, ... }.
    uint8_t t;
    XTDerReader* seq = [[[XTDerReader alloc] initWithData:keyPkcs1] readConstructed:&t];
    (void)[seq readTLV:&t]; // version
    NSData* n = [seq readTLV:&t];
    NSData* e = [seq readTLV:&t];
    NSData* d = [seq readTLV:&t];
    if (!n || !e || !d)
        {
        if (error)
            *error = @"could not parse generated key";
        return nil;
        }

    // CertificationRequestInfo
    NSData* subject = [XTDer sequence:@[ [XTDer setOf:@[ [XTDer sequence:@[
                                                    [XTDer oid:@"2.5.4.3"], [XTDer utf8String:cn]
                                                ]] ]] ]];
    NSData* rsaPubKey = [XTDer sequence:@[ [XTDer integer:n], [XTDer integer:e] ]];
    NSData* spki = [XTDer sequence:@[
        [XTDer sequence:@[ [XTDer oid:@"1.2.840.113549.1.1.1"], [XTDer null] ]],
        [XTDer bitString:rsaPubKey
              unusedBits:0]
    ]];
    NSData* attrs = [XTDer implicitTag:0 constructed:YES content:[XTDer sequence:@[]]]; // no attributes
    NSData* cri = [XTDer sequence:@[ [XTDer integerFromU64:0], subject, spki, attrs ]];

    // sign CRI with the new key (SHA-256 + RSA PKCS#1)
    NSData* criHash = [XTCrypto sha256:cri];
    NSData* algo = [XTDer sequence:@[ [XTDer oid:@"2.16.840.1.101.3.4.2.1"], [XTDer null] ]];
    NSData* digestInfo = [XTDer sequence:@[ algo, [XTDer octetString:criHash] ]];
    NSData* sig = [XTCrypto rsaSignPKCS1:digestInfo modulus:n privateExponent:d];
    if (!sig)
        {
        if (error)
            *error = @"CSR self-signature failed";
        return nil;
        }

    NSData* csr = [XTDer sequence:@[
        cri,
        [XTDer sequence:@[ [XTDer oid:@"1.2.840.113549.1.1.11"], [XTDer null] ]], // sha256WithRSA
        [XTDer bitString:sig
              unusedBits:0]
    ]];

    // PEM
    NSString* b64 = [csr base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength];
    return [NSString stringWithFormat:
                         @"-----BEGIN CERTIFICATE REQUEST-----\n%@\n-----END CERTIFICATE REQUEST-----\n", b64];
    }

- (nullable NSData*)createDevelopmentCertificate:(NSString*)csrPem
                                           error:(NSString* _Nullable* _Nullable)error
    {
    NSDictionary* payload = @{@"data" : @{
        @"type" : @"certificates",
        @"attributes" : @{@"certificateType" : @"DEVELOPMENT", @"csrContent" : csrPem}
    }};
    NSData* body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    XTHttpsResponse* r = [self call:@"POST" path:@"/v1/certificates" body:body error:error];
    if (!r)
        return nil;
    NSString* bodyStr = [[NSString alloc] initWithData:r.body encoding:NSUTF8StringEncoding];
    if (r.status != 201 && r.status != 200)
        {
        if (error)
            *error = [NSString stringWithFormat:@"create cert HTTP %ld: %@", (long)r.status, bodyStr];
        return nil;
        }
    NSDictionary* j = [NSJSONSerialization JSONObjectWithData:r.body options:0 error:NULL];
    NSString* content = j[@"data"][@"attributes"][@"certificateContent"];
    if (!content)
        {
        if (error)
            *error = @"no certificateContent in response";
        return nil;
        }
    NSData* der = [[NSData alloc] initWithBase64EncodedString:content
                                                      options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!der)
        {
        if (error)
            *error = @"bad certificateContent base64";
        return nil;
        }
    return der;
    }

- (nullable NSData*)fetchProfileMatching:(nullable NSString*)nameFilter
                                   error:(NSString* _Nullable* _Nullable)error
    {
    NSData* list = [self listProfiles:error];
    if (!list)
        return nil;
    NSDictionary* j = [NSJSONSerialization JSONObjectWithData:list options:0 error:NULL];
    NSArray* data = j[@"data"];
    for (NSDictionary* prof in data)
        {
        NSDictionary* a = prof[@"attributes"];
        NSString* name = a[@"name"];
        if (nameFilter && [name rangeOfString:nameFilter].location == NSNotFound)
            continue;
        NSString* content = a[@"profileContent"];
        if (content)
            return [[NSData alloc] initWithBase64EncodedString:content
                                                       options:NSDataBase64DecodingIgnoreUnknownCharacters];
        }
    if (error)
        *error = nameFilter ? [NSString stringWithFormat:@"no profile matching '%@'", nameFilter]
                            : @"no profiles found";
    return nil;
    }

+ (nullable NSData*)fetchAppleCA:(NSString*)name
                           error:(NSString* _Nullable* _Nullable)error
    {
    NSString* path = [NSString stringWithFormat:@"/certificateauthority/%@.cer", name];
    XTHttpsResponse* r = [XTHttps request:@"GET" host:@"www.apple.com" path:path headers:nil body:nil];
    if (r.status < 0)
        {
        if (error)
            *error = r.error;
        return nil;
        }
    if (r.status != 200)
        {
        if (error)
            *error = [NSString stringWithFormat:@"fetch %@ HTTP %ld", name, (long)r.status];
        return nil;
        }
    return r.body; // DER
    }

+ (nullable NSData*)entitlementsFromProfile:(NSData*)mobileProvision
    {
    // ContentInfo SEQ { OID, [0]{ SignedData SEQ { ver, digestAlgs SET,
    //   encapContentInfo SEQ { eContentType OID, [0]{ eContent OCTET=plist } } ...}}}
    uint8_t t;
    XTDerReader* ci = [[[XTDerReader alloc] initWithData:mobileProvision] readConstructed:&t];
    if (!ci)
        return nil;
    (void)[ci readTLV:&t];                       // signedData OID
    XTDerReader* ctx0 = [ci readConstructed:&t]; // [0]
    if (!ctx0)
        return nil;
    XTDerReader* sd = [ctx0 readConstructed:&t]; // SignedData SEQ
    if (!sd)
        return nil;
    (void)[sd readTLV:&t];                      // version
    (void)[sd readElement];                     // digestAlgorithms SET
    XTDerReader* eci = [sd readConstructed:&t]; // encapContentInfo SEQ
    if (!eci)
        return nil;
    (void)[eci readTLV:&t];                           // eContentType OID
    XTDerReader* econtext = [eci readConstructed:&t]; // [0]
    if (!econtext)
        return nil;
    NSData* plist = [econtext readTLV:&t]; // eContent OCTET STRING = the plist
    if (!plist || t != 0x04)
        return nil;

    NSDictionary* prof = [NSPropertyListSerialization propertyListWithData:plist options:0 format:NULL error:NULL];
    NSDictionary* ent = prof[@"Entitlements"];
    if (![ent isKindOfClass:NSDictionary.class])
        return nil;
    return [NSPropertyListSerialization dataWithPropertyList:ent
                                                      format:NSPropertyListXMLFormat_v1_0
                                                     options:0
                                                       error:NULL];
    }

@end
