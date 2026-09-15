//
//  XTIdentity.h — the signing identity, loaded from a PEM bundle.
//
//  identity.pem is the pivot artifact (docs/mobile/signing.md): one file with
//  the leaf certificate first, then any chain certificates, then the RSA
//  private key (PKCS#1 or PKCS#8). Optionally custom armored blocks carry the
//  provisioning profile and entitlements. Once it exists, signing is offline
//  and host-neutral — no keychain, no network.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTIdentity : NSObject

@property(nonatomic, readonly) NSData* leafCertDer;
@property(nonatomic, readonly) NSArray<NSData*>* chainDer;
@property(nonatomic, readonly) NSData* modulus;                   // RSA n, big-endian
@property(nonatomic, readonly) NSData* privateExponent;           // RSA d, big-endian
@property(nonatomic, readonly, nullable) NSData* entitlementsXml; // if bundled

// Parse a PEM bundle. `passphrase` decrypts an ENCRYPTED PRIVATE KEY block
// (pass nil / empty for a plain key). Returns nil with *error on a malformed /
// incomplete bundle, an unparseable key, or a wrong passphrase.
+ (nullable instancetype)identityFromPEM:(NSData*)pem
                              passphrase:(nullable NSString*)passphrase
                                   error:(NSString* _Nullable* _Nullable)error;

// Assemble a PEM bundle from parts. The key is stored verbatim under the given
// label — "PRIVATE KEY" for a plain PKCS#8, "ENCRYPTED PRIVATE KEY" for a
// PBES2-wrapped one (the Route 2 Mac export uses the encrypted form).
+ (NSData*)pemBundleWithLeaf:(NSData*)leafDer
                       chain:(NSArray<NSData*>*)chainDer
                    keyBlock:(NSData*)keyDer
                    keyLabel:(NSString*)keyLabel
             entitlementsXml:(nullable NSData*)entitlementsXml;

@end

NS_ASSUME_NONNULL_END
