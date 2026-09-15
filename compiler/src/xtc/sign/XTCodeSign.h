//
//  XTCodeSign.h — turn an (ad-hoc) Mach-O into a developer-signed one.
//
//  The last stage. Given a finished Mach-O and an identity (leaf cert + chain +
//  RSA key), it rebuilds the embedded signature SuperBlob — a full
//  CodeDirectory (SHA-256 page hashes + optional entitlement/requirement
//  special slots) plus the CMS SignedData over it — and re-splices it into the
//  file: the code never moves, only the __LINKEDIT trailer grows. No Apple APIs.
//
//  Gate: the output validates under `codesign -v`.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTCodeSign : NSObject

// Re-sign `machO`. `identifier` is the signing identifier (bundle id / binary
// name). `leafCertDer`/`chainDer`/`modulus`/`privateExponent` are the identity.
// `entitlementsXml` is the entitlements plist bytes to embed (slots 5 + 7), or
// nil for none. `signingTime` is a fixed "YYYYMMDDhhmmssZ". Returns the signed
// Mach-O, or nil (with *error set) on a shape it cannot handle.
+ (nullable NSData*)resign:(NSData*)machO
                identifier:(NSString*)identifier
               leafCertDer:(NSData*)leafCertDer
                  chainDer:(NSArray<NSData*>*)chainDer
                   modulus:(NSData*)modulus
           privateExponent:(NSData*)privateExponent
           entitlementsXml:(nullable NSData*)entitlementsXml
                 infoPlist:(nullable NSData*)infoPlist
             codeResources:(nullable NSData*)codeResources
               signingTime:(NSString*)signingTime
                     error:(NSString* _Nullable* _Nullable)error;

@end

NS_ASSUME_NONNULL_END
