//
//  XTIdentityExport.m — see XTIdentityExport.h.
//

#import "XTIdentityExport.h"
#import "XTIdentity.h"

#if defined(__APPLE__)
@import Security;

@implementation XTIdentityExport

// Best-effort issuer chain: evaluate a trust over the leaf and copy the certs
// above it. A self-signed leaf yields an empty chain (its own root is the leaf).
static NSArray<NSData *> *chainAboveLeaf(SecCertificateRef leaf) {
    NSMutableArray<NSData *> *chain = [NSMutableArray array];
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    SecTrustRef trust = NULL;
    if (SecTrustCreateWithCertificates(leaf, policy, &trust) == errSecSuccess && trust) {
        SecTrustResultType r; (void)SecTrustEvaluateWithError(trust, NULL); (void)r;
        CFArrayRef certs = SecTrustCopyCertificateChain(trust);
        if (certs) {
            CFIndex n = CFArrayGetCount(certs);
            for (CFIndex i = 1; i < n; i++) {   // skip [0] = leaf
                SecCertificateRef c = (SecCertificateRef)CFArrayGetValueAtIndex(certs, i);
                CFDataRef d = SecCertificateCopyData(c);
                if (d) { [chain addObject:(__bridge NSData *)d]; CFRelease(d); }
            }
            CFRelease(certs);
        }
    }
    if (trust) CFRelease(trust);
    if (policy) CFRelease(policy);
    return chain;
}

// The entitlements XML from a .mobileprovision (a CMS-signed plist): decode the
// CMS, read the Entitlements dict, re-serialise it as an XML plist.
static NSData *entitlementsFromProfile(NSString *path) {
    NSData *raw = [NSData dataWithContentsOfFile:path];
    if (!raw) return nil;
    CMSDecoderRef dec = NULL;
    if (CMSDecoderCreate(&dec) != errSecSuccess) return nil;
    CMSDecoderUpdateMessage(dec, raw.bytes, raw.length);
    CMSDecoderFinalizeMessage(dec);
    CFDataRef content = NULL;
    CMSDecoderCopyContent(dec, &content);
    CFRelease(dec);
    if (!content) return nil;
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:(__bridge NSData *)content
                              options:0 format:NULL error:NULL];
    CFRelease(content);
    NSDictionary *ent = plist[@"Entitlements"];
    if (![ent isKindOfClass:NSDictionary.class]) return nil;
    return [NSPropertyListSerialization dataWithPropertyList:ent
                format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
}

+ (BOOL)exportIdentityMatching:(NSString *)nameSubstring
                    passphrase:(NSString *)passphrase
                  keychainPath:(nullable NSString *)keychainPath
                   profilePath:(nullable NSString *)profilePath
                        toPath:(NSString *)outPath
                         error:(NSString *_Nullable*_Nullable)error {
    #define FAIL(m) do { if (error) *error = m; return NO; } while (0)

    NSMutableDictionary *q = [@{
        (__bridge id)kSecClass:       (__bridge id)kSecClassIdentity,
        (__bridge id)kSecReturnRef:   @YES,
        (__bridge id)kSecMatchLimit:  (__bridge id)kSecMatchLimitAll,
    } mutableCopy];
    if (keychainPath) {
        SecKeychainRef kc = NULL;
        // SecKeychainOpen is deprecated but is the only way to target a specific
        // file keychain; the data-protection keychain has no path. Fine here.
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (SecKeychainOpen(keychainPath.fileSystemRepresentation, &kc) == errSecSuccess && kc)
            q[(__bridge id)kSecMatchSearchList] = @[(__bridge id)kc];
        #pragma clang diagnostic pop
    }
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
    if (st != errSecSuccess || !result) FAIL(@"no code-signing identities found in the keychain");
    NSArray *identities = (__bridge_transfer NSArray *)result;

    SecIdentityRef match = NULL; SecCertificateRef matchCert = NULL;
    for (id obj in identities) {
        SecIdentityRef ident = (__bridge SecIdentityRef)obj;
        SecCertificateRef cert = NULL;
        if (SecIdentityCopyCertificate(ident, &cert) != errSecSuccess || !cert) continue;
        CFStringRef cn = NULL; SecCertificateCopyCommonName(cert, &cn);
        NSString *name = (__bridge_transfer NSString *)cn;
        if (name && [name rangeOfString:nameSubstring].location != NSNotFound) {
            match = ident; matchCert = cert; break;
        }
        CFRelease(cert);
    }
    if (!match) FAIL(([NSString stringWithFormat:@"no identity matching '%@'", nameSubstring]));

    NSData *leafDer = (__bridge_transfer NSData *)SecCertificateCopyData(matchCert);
    NSArray<NSData *> *chain = chainAboveLeaf(matchCert);

    SecKeyRef priv = NULL;
    if (SecIdentityCopyPrivateKey(match, &priv) != errSecSuccess || !priv) {
        CFRelease(matchCert);
        FAIL(@"the identity's private key is not accessible (not exportable?)");
    }
    // macOS will not hand out a bare private key; SecItemExport wraps it as a
    // PBES2 EncryptedPrivateKeyInfo under `passphrase`. That encrypted blob is
    // stored verbatim in the PEM, and the signer decrypts it (XTPkcs8) with the
    // same passphrase — so the key is never on disk in the clear. Exporting a
    // key prompts once for keychain permission (expected, one-time).
    SecItemImportExportKeyParameters params; memset(&params, 0, sizeof params);
    params.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;
    params.passphrase = (__bridge CFTypeRef)passphrase;
    CFDataRef wrapped = NULL;
    OSStatus est = SecItemExport(priv, kSecFormatWrappedPKCS8, 0, &params, &wrapped);
    CFRelease(priv); CFRelease(matchCert);
    if (est != errSecSuccess || !wrapped)
        FAIL(([NSString stringWithFormat:@"could not export the private key (OSStatus %d)", (int)est]));
    NSData *keyDer = (__bridge_transfer NSData *)wrapped;

    NSData *ent = profilePath ? entitlementsFromProfile(profilePath) : nil;
    NSData *pem = [XTIdentity pemBundleWithLeaf:leafDer chain:chain
                         keyBlock:keyDer keyLabel:@"ENCRYPTED PRIVATE KEY"
                         entitlementsXml:ent];
    if (![pem writeToFile:outPath atomically:YES]) FAIL(@"could not write the PEM bundle");
    // The bundle holds a private key — keep it owner-only.
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600}
                                     ofItemAtPath:outPath error:NULL];
    return YES;
    #undef FAIL
}

@end

#else   // ── non-Apple: no keychain to read ──

@implementation XTIdentityExport
+ (BOOL)exportIdentityMatching:(NSString *)nameSubstring
                    passphrase:(NSString *)passphrase
                  keychainPath:(nullable NSString *)keychainPath
                   profilePath:(nullable NSString *)profilePath
                        toPath:(NSString *)outPath
                         error:(NSString *_Nullable*_Nullable)error {
    if (error) *error = @"--export-identity is macOS-only "
                        "(it reads the Security-framework keychain)";
    return NO;
}
@end

#endif
