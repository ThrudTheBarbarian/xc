//
//  XTIdentityExport.h — Route 2: pull a signing identity out of the Mac.
//
//  macOS-only. Uses the Security framework ONCE to read a code-signing identity
//  (certificate + chain + private key) from a keychain and write it into the
//  PEM bundle XTIdentity consumes. After that the bundle signs anywhere,
//  offline — that is the whole point of Route 2 (docs/mobile/signing.md Phase B).
//  On non-Apple hosts this is a stub that reports it is unavailable.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTIdentityExport : NSObject

// Find the code-signing identity whose certificate common name contains
// `nameSubstring` (as `security find-identity` matches), and write a PEM
// identity bundle to `outPath`. `keychainPath` is an optional specific
// keychain (nil = the default search list). `profilePath` is an optional
// .mobileprovision whose entitlements are folded into the bundle.
// Returns YES on success; on failure sets *error and returns NO.
+ (BOOL)exportIdentityMatching:(NSString*)nameSubstring
                    passphrase:(NSString*)passphrase
                  keychainPath:(nullable NSString*)keychainPath
                   profilePath:(nullable NSString*)profilePath
                        toPath:(NSString*)outPath
                         error:(NSString* _Nullable* _Nullable)error;

@end

NS_ASSUME_NONNULL_END
