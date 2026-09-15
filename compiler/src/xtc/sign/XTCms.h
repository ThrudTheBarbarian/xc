//
//  XTCms.h — the CMS/PKCS#7 SignedData blob Apple code signing embeds.
//
//  A DETACHED SignedData (no eContent) whose SignerInfo carries the signed
//  attributes Apple checks — contentType, messageDigest (= SHA-256 of the
//  primary CodeDirectory), signingTime — with the signer certificate and its
//  chain in the cert set. The signature is RSA-PKCS1 over SHA-256 of the
//  DER-encoded signed-attributes SET. Built on XTDer / XTDerReader / XTCrypto.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTCms : NSObject

// Build the SignedData. `codeDirectorySha256` is the digest of the primary
// CodeDirectory blob. `signerCertDer` is the leaf; `chainDer` the intermediates
// (+ root) to embed. `keyModulus`/`keyPrivateExponent` are the signer key's n
// and d (big-endian). `signingTime` is a fixed "YYYYMMDDhhmmssZ" Generalized
// time string (pass a constant so two builds are byte-identical in length).
// Returns the DER SignedData (the bytes that go in SuperBlob slot 0x10000's
// blob body), or nil on malformed inputs.
+ (nullable NSData*)signedDataForCodeDirectorySha256:(NSData*)codeDirectorySha256
                                       signerCertDer:(NSData*)signerCertDer
                                            chainDer:(NSArray<NSData*>*)chainDer
                                          keyModulus:(NSData*)keyModulus
                                  keyPrivateExponent:(NSData*)keyPrivateExponent
                                         signingTime:(NSString*)signingTime;

@end

NS_ASSUME_NONNULL_END
