//
//  XTDerReader.h — a minimal ASN.1 DER cursor.
//
//  Just enough to slice fields out of a DER structure we did not build — the
//  one case being an X.509 certificate whose issuer Name and serialNumber the
//  CMS SignerInfo needs (as IssuerAndSerialNumber). It reads one TLV at a time
//  and can descend into a constructed one; it does not interpret values.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTDerReader : NSObject

- (instancetype)initWithData:(NSData*)data;

// Cursor position within the current sequence's content.
@property(nonatomic, readonly) BOOL atEnd;

// Read the next TLV. On success sets *tag and returns its VALUE bytes (no
// tag/length); the cursor advances past it. Returns nil at end / on malformed.
- (nullable NSData*)readTLV:(uint8_t*)tag;

// Look at the next TLV's identifier octet without consuming it. NO on end.
- (BOOL)peekNextTag:(uint8_t*)tag;

// Read the next TLV and return the WHOLE element (tag+length+value) — used when
// a sub-structure must be re-emitted verbatim (issuer Name goes into the CMS
// exactly as it appears in the cert).
- (nullable NSData*)readElement;

// Descend into the next TLV (must be constructed): returns a reader over its
// content, leaving this cursor past the element.
- (nullable XTDerReader*)readConstructed:(uint8_t*)tag;

// Convenience: from a full X.509 Certificate DER, pull the issuer Name element
// (verbatim TLV) and the serialNumber INTEGER value. Returns NO if the shape
// is not a certificate.
+ (BOOL)certificate:(NSData*)certDer
         issuerName:(NSData* _Nullable* _Nonnull)issuerOut
       serialNumber:(NSData* _Nullable* _Nonnull)serialOut;

@end

NS_ASSUME_NONNULL_END
