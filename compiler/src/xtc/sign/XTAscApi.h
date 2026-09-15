//
//  XTAscApi.h — App Store Connect API client (Route 1).
//
//  Authenticates with an ASC API key (ES256 JWT from the .p8), then automates
//  the signing-identity acquisition: generate an RSA keypair, build a CSR,
//  create an Apple Development certificate, and fetch a provisioning profile.
//  Transport is XTHttps (Mbed TLS); the JWT and keygen use PSA (Mbed TLS);
//  the CSR is built in-house (XTDer + XTCrypto). No Apple APIs.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTAscApi : NSObject

// Configure with the three ASC key artifacts. `p8Path` is the AuthKey_*.p8.
- (nullable instancetype)initWithIssuerId:(NSString*)issuerId
                                    keyId:(NSString*)keyId
                                   p8Path:(NSString*)p8Path
                                    error:(NSString* _Nullable* _Nullable)error;

// Read-only: GET /v1/certificates, returns the raw JSON (for listing/inspection).
- (nullable NSData*)listCertificates:(NSString* _Nullable* _Nullable)error;

// Revoke a certificate by its ASC id (DELETE /v1/certificates/{id}). Frees a
// slot so a fresh --fetch-identity can create one. Returns YES on success.
- (BOOL)revokeCertificate:(NSString*)certId error:(NSString* _Nullable* _Nullable)error;
// Read-only: GET /v1/profiles.
- (nullable NSData*)listProfiles:(NSString* _Nullable* _Nullable)error;

// Generate an RSA-2048 keypair (PSA) and return its PKCS#1 DER via *keyPkcs1Der;
// returns the CSR as PEM text, or nil on failure.
- (nullable NSString*)generateKeypairAndCSRWithCommonName:(NSString*)cn
                                              keyPkcs1Der:(NSData* _Nullable* _Nonnull)keyOut
                                                    error:(NSString* _Nullable* _Nullable)error;

// CREATE a real Apple Development certificate from the CSR (POST — consumes an
// account cert slot). Returns the issued certificate DER, or nil.
- (nullable NSData*)createDevelopmentCertificate:(NSString*)csrPem
                                           error:(NSString* _Nullable* _Nullable)error;

// Fetch the first profile whose name contains `nameFilter` (nil = first
// development profile). Returns the .mobileprovision bytes, or nil.
- (nullable NSData*)fetchProfileMatching:(nullable NSString*)nameFilter
                                   error:(NSString* _Nullable* _Nullable)error;

// Fetch a public Apple CA intermediate/root (DER) from Apple's certificate
// authority, e.g. @"AppleWWDRCAG3" or @"AppleIncRootCertificate". The API
// returns only the leaf, so the chain must be assembled from these.
+ (nullable NSData*)fetchAppleCA:(NSString*)name
                           error:(NSString* _Nullable* _Nullable)error;

// Extract the Entitlements dict from a .mobileprovision (a CMS-signed plist),
// re-serialised as an XML plist ready for the CodeDirectory entitlements slot.
// Host-neutral: walks the CMS for its eContent (no CMSDecoder). nil if absent.
+ (nullable NSData*)entitlementsFromProfile:(NSData*)mobileProvision;

@end

NS_ASSUME_NONNULL_END
