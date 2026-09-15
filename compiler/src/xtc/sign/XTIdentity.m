//
//  XTIdentity.m — see XTIdentity.h.
//

#import "XTIdentity.h"
#import "XTDerReader.h"
#import "XTPkcs8.h"

// Custom PEM block labels for the non-standard parts.
static NSString * const PEM_ENTITLEMENTS = @"XCC ENTITLEMENTS";

@implementation XTIdentity

// Split a PEM document into (label, der) blocks.
+ (NSArray<NSDictionary *> *)blocksFromPEM:(NSData *)pem {
    NSString *text = [[NSString alloc] initWithData:pem encoding:NSUTF8StringEncoding];
    if (!text) return @[];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSScanner *sc = [NSScanner scannerWithString:text];
    sc.charactersToBeSkipped = nil;
    while (![sc isAtEnd]) {
        NSString *begin = nil;
        if (![sc scanUpToString:@"-----BEGIN " intoString:NULL]) { }
        if (![sc scanString:@"-----BEGIN " intoString:NULL]) break;
        if (![sc scanUpToString:@"-----" intoString:&begin]) break;
        [sc scanString:@"-----" intoString:NULL];
        NSString *body = nil;
        NSString *endMarker = [NSString stringWithFormat:@"-----END %@-----", begin];
        if (![sc scanUpToString:endMarker intoString:&body]) break;
        [sc scanString:endMarker intoString:NULL];
        NSData *der = [[NSData alloc] initWithBase64EncodedString:body
                         options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (der) [out addObject:@{@"label": begin, @"der": der}];
    }
    return out;
}

// Extract RSA n (modulus) and d (privateExponent) from a key DER, unwrapping
// PKCS#8 PrivateKeyInfo to the inner PKCS#1 RSAPrivateKey if needed.
+ (BOOL)rsaKeyFromDer:(NSData *)der modulus:(NSData **)nOut privateExponent:(NSData **)dOut {
    // Try PKCS#1 first: SEQ { version, n, e, d, ... }.
    XTDerReader *top = [[XTDerReader alloc] initWithData:der];
    uint8_t t;
    XTDerReader *seq = [top readConstructed:&t];
    if (!seq) return NO;
    NSData *first = [seq readTLV:&t];                 // version INTEGER
    if (!first || t != 0x02) return NO;
    // Peek: PKCS#8 has an AlgorithmIdentifier SEQUENCE next, PKCS#1 has INTEGER n.
    uint8_t nt;
    if (![seq peekNextTag:&nt]) return NO;
    if (nt == 0x30) {
        // PKCS#8: skip algo SEQ, then OCTET STRING wraps the PKCS#1 key.
        (void)[seq readElement];                      // algorithm
        NSData *inner = [seq readTLV:&t];             // privateKey OCTET STRING
        if (!inner || t != 0x04) return NO;
        return [self rsaKeyFromDer:inner modulus:nOut privateExponent:dOut];
    }
    // PKCS#1: next is n, then e, then d.
    NSData *n = [seq readTLV:&t]; if (!n || t != 0x02) return NO;
    (void)[seq readTLV:&t];                           // e
    NSData *d = [seq readTLV:&t]; if (!d || t != 0x02) return NO;
    *nOut = n; *dOut = d;
    return YES;
}

+ (nullable instancetype)identityFromPEM:(NSData *)pem
                              passphrase:(nullable NSString *)passphrase
                                   error:(NSString *_Nullable*_Nullable)error {
    #define FAIL(m) do { if (error) *error = m; return nil; } while (0)
    NSArray<NSDictionary *> *blocks = [self blocksFromPEM:pem];
    NSMutableArray<NSData *> *certs = [NSMutableArray array];
    NSData *keyDer = nil, *ent = nil; BOOL keyEncrypted = NO;
    for (NSDictionary *blk in blocks) {
        NSString *label = blk[@"label"]; NSData *der = blk[@"der"];
        if ([label isEqualToString:@"CERTIFICATE"]) [certs addObject:der];
        else if ([label isEqualToString:@"ENCRYPTED PRIVATE KEY"]) { keyDer = der; keyEncrypted = YES; }
        else if ([label hasSuffix:@"PRIVATE KEY"]) keyDer = der;   // RSA/PKCS#8/plain
        else if ([label isEqualToString:PEM_ENTITLEMENTS]) ent = der;
    }
    if (certs.count == 0) FAIL(@"no CERTIFICATE in the identity bundle");
    if (!keyDer)          FAIL(@"no PRIVATE KEY in the identity bundle");
    if (keyEncrypted) {
        if (passphrase == nil) FAIL(@"the key is encrypted — a passphrase is required");
        NSString *derr = nil;
        NSData *plain = [XTPkcs8 decryptEncryptedPrivateKeyInfo:keyDer passphrase:passphrase error:&derr];
        if (!plain) FAIL((derr ?: @"could not decrypt the private key"));
        keyDer = plain;
    }
    NSData *n = nil, *d = nil;
    if (![self rsaKeyFromDer:keyDer modulus:&n privateExponent:&d])
        FAIL(@"private key is not a parseable RSA key");

    XTIdentity *ident = [XTIdentity new];
    ident->_leafCertDer = certs[0];
    ident->_chainDer = [certs subarrayWithRange:NSMakeRange(1, certs.count - 1)];
    ident->_modulus = n;
    ident->_privateExponent = d;
    ident->_entitlementsXml = ent;
    return ident;
    #undef FAIL
}

+ (NSString *)pemBlock:(NSString *)label der:(NSData *)der {
    NSString *b64 = [der base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength];
    return [NSString stringWithFormat:@"-----BEGIN %@-----\n%@\n-----END %@-----\n", label, b64, label];
}

+ (NSData *)pemBundleWithLeaf:(NSData *)leafDer
                        chain:(NSArray<NSData *> *)chainDer
                     keyBlock:(NSData *)keyDer
                    keyLabel:(NSString *)keyLabel
              entitlementsXml:(nullable NSData *)entitlementsXml {
    NSMutableString *s = [NSMutableString string];
    [s appendString:[self pemBlock:@"CERTIFICATE" der:leafDer]];
    for (NSData *c in chainDer) [s appendString:[self pemBlock:@"CERTIFICATE" der:c]];
    [s appendString:[self pemBlock:keyLabel der:keyDer]];
    if (entitlementsXml) [s appendString:[self pemBlock:PEM_ENTITLEMENTS der:entitlementsXml]];
    return [s dataUsingEncoding:NSUTF8StringEncoding];
}

@end
