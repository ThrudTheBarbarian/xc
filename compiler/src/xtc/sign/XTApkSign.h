// XTApkSign — APK Signature Scheme v2, in-house.
//
// v1 (JAR signing) is not enough: Android 11 and later reject a package whose
// targetSdk is 30+ if it carries only a v1 signature, and ours targets 35. v2
// signs the WHOLE file rather than entry by entry, which is also why it can be
// done here in one pass over bytes we already have.
//
// Everything it needs already existed for Apple code signing — SHA-256, RSA
// PKCS#1 v1.5, and a DER writer — so this is the format, not the cryptography.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTApkSign : NSObject

// A self-signed X.509 certificate for a freshly made key. The APK carries the
// certificate, and Android's only interest in it is identity: two packages are
// "the same app" when the signing certificate matches. A debug certificate
// asserts nothing else, so the subject is fixed and the validity generous.
+ (nullable NSData*)selfSignedCertificateWithModulus:(NSData*)modulus
                                      publicExponent:(NSData*)publicExponent
                                     privateExponent:(NSData*)privateExponent
                                          commonName:(NSString*)commonName
                                               error:(NSError**)error;

// Insert an APK Signing Block carrying a v2 signature.
//
// The block goes exactly where the central directory used to start, and the
// EOCD's central-directory offset is then moved past it. The digest is taken
// over three regions — the entry contents, the central directory, and the EOCD
// with its central-directory offset reading as the BLOCK's offset. That last
// one looks circular and is not: the block lands at the old offset, so the
// value to digest is the one the unsigned file already has.
+ (nullable NSData*)signedApkFromUnsigned:(NSData*)apk
                                  certDer:(NSData*)certDer
                                  modulus:(NSData*)modulus
                           publicExponent:(NSData*)publicExponent
                          privateExponent:(NSData*)privateExponent
                                    error:(NSError**)error;

@end

NS_ASSUME_NONNULL_END
