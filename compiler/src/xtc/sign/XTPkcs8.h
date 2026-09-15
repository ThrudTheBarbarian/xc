//
//  XTPkcs8.h — decrypt an encrypted PKCS#8 private key (PBES2).
//
//  The macOS keychain only exports a private key passphrase-WRAPPED
//  (SecItemExport → EncryptedPrivateKeyInfo, PBES2 { PBKDF2-HMAC-SHA1, 3DES-CBC }).
//  Route 2 stores that verbatim in the identity PEM; this decrypts it back to a
//  plain PKCS#8 with the passphrase — in-house (PBKDF2 + 3DES), no Apple APIs, so
//  a signature can be produced on any host offline. Oracle: openssl pkcs8.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTPkcs8 : NSObject

// EncryptedPrivateKeyInfo DER + passphrase → inner PKCS#8 PrivateKeyInfo DER.
// Supports PBES2 with PBKDF2-HMAC-SHA1/SHA256 and des-ede3-cbc or aes-128/256-cbc
// (the shapes macOS and openssl emit). Returns nil with *error on wrong
// passphrase / unsupported algorithm.
+ (nullable NSData*)decryptEncryptedPrivateKeyInfo:(NSData*)der
                                        passphrase:(NSString*)passphrase
                                             error:(NSString* _Nullable* _Nullable)error;

// Wrap a plain PKCS#8 (or PKCS#1) key as a PBES2 EncryptedPrivateKeyInfo
// (PBKDF2-HMAC-SHA1, 2048 iters, des-ede3-cbc) under `passphrase` — the same
// shape decrypt reads, so a Route-1 key is stored encrypted like a Route-2 one.
// Returns nil on failure (e.g. no OS randomness).
+ (nullable NSData*)encryptPrivateKey:(NSData*)pkcs8OrPkcs1Der
                           passphrase:(NSString*)passphrase
                                error:(NSString* _Nullable* _Nullable)error;

@end

NS_ASSUME_NONNULL_END
