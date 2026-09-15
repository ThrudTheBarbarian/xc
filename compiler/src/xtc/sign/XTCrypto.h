//
//  XTCrypto.h — the crypto primitives Apple code signing needs, in-house.
//
//  No OpenSSL, no CommonCrypto: the whole point of the toolchain is that it
//  needs no other libraries, and that must hold for the signer too (it runs on
//  Linux and Windows). So this is a self-contained SHA-1, SHA-256, and RSA
//  PKCS#1 v1.5 signature (big-integer modexp via Montgomery multiplication).
//
//  Oracle: signatures verify with `openssl` against the matching public key;
//  digests match `shasum`.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTCrypto : NSObject

+ (NSData*)sha1:(NSData*)data;   // 20 bytes
+ (NSData*)sha256:(NSData*)data; // 32 bytes

// RSASSA-PKCS1-v1_5 sign. `digestInfo` is the DER DigestInfo { algo, digest };
// this pads it to the modulus width (0x00 01 FF..FF 00 || digestInfo) and
// raises it to the private exponent mod n. `modulus` and `privateExponent` are
// big-endian magnitudes as they appear in the key (n and d). Returns a
// signature exactly `modulus.length` bytes, or nil on a malformed input.
+ (nullable NSData*)rsaSignPKCS1:(NSData*)digestInfo
                         modulus:(NSData*)modulus
                 privateExponent:(NSData*)privateExponent;

// Raw modexp helper (base^exp mod modulus), big-endian in and out — exposed so
// the JWT/ES path and tests can reuse the bignum without RSA padding.
+ (nullable NSData*)modexpBase:(NSData*)base
                      exponent:(NSData*)exponent
                       modulus:(NSData*)modulus;

// Generate an RSA key. Returns @{@"n": modulus, @"e": publicExponent,
// @"d": privateExponent}, each a big-endian magnitude, or nil if the machine
// has no entropy source.
//
// Here so that making a DEBUG signing key needs no JDK and no `keytool` — the
// same reason nothing else in this toolchain shells out. `e` is 65537.
+ (nullable NSDictionary<NSString*, NSData*>*)rsaGenerateKeyOfBits:(int)bits;

@end

NS_ASSUME_NONNULL_END
