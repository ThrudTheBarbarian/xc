//
//  XTDer.h — a minimal ASN.1 DER encoder.
//
//  Just enough of DER to build the structures Apple code signing needs:
//  X.509 certificates (for the CMS cert set), the CMS/PKCS#7 SignedData blob,
//  and a PKCS#10 CSR. NOT a general ASN.1 library — it encodes the tags this
//  toolchain emits and nothing else. Every method returns a complete TLV
//  (tag + DER length + value) as NSData, so structures compose by nesting.
//
//  DER (not BER): definite lengths, minimal integer encodings, sorted SETs.
//  Oracle: any blob this produces round-trips through `openssl asn1parse`.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTDer : NSObject

// ── Primitives ──────────────────────────────────────────────────────────
// A raw TLV: one identifier octet `tag`, a DER length, then `content` verbatim.
+ (NSData*)tlv:(uint8_t)tag content:(NSData*)content;

// INTEGER from a big-endian magnitude. A leading 0x00 is prepended when the
// top bit is set, so the value stays positive (the code-signing world has no
// negative integers). An empty/all-zero magnitude encodes as INTEGER 0.
+ (NSData*)integer:(NSData*)bigEndianMagnitude;
+ (NSData*)integerFromU64:(uint64_t)value;

+ (NSData*)boolean:(BOOL)value;
+ (NSData*)null;
+ (NSData*)octetString:(NSData*)bytes;

// BIT STRING with `unusedBits` (0 for byte-aligned content, which is all we use).
+ (NSData*)bitString:(NSData*)bytes unusedBits:(uint8_t)unusedBits;

// OBJECT IDENTIFIER from dotted-decimal, e.g. @"1.2.840.113549.1.1.11".
+ (NSData*)oid:(NSString*)dotted;

+ (NSData*)utf8String:(NSString*)string;
+ (NSData*)printableString:(NSString*)string;
+ (NSData*)ia5String:(NSString*)string;
// UTCTime "YYMMDDhhmmssZ" / GeneralizedTime "YYYYMMDDhhmmssZ" from the string.
+ (NSData*)utcTime:(NSString*)yymmddhhmmssZ;
+ (NSData*)generalizedTime:(NSString*)yyyymmddhhmmssZ;

// ── Constructors ────────────────────────────────────────────────────────
+ (NSData*)sequence:(NSArray<NSData*>*)elements;
// SET OF — DER requires the members sorted by their encoded bytes; this sorts.
+ (NSData*)setOf:(NSArray<NSData*>*)elements;
// SET (structural, e.g. an X.509 RDN) — members kept in the given order.
+ (NSData*)set:(NSArray<NSData*>*)elements;

// Context-specific tags. EXPLICIT wraps `content` (already a TLV) in [n];
// IMPLICIT retags `contentTLV` (its identifier is replaced). `constructed`
// picks the 0x20 bit — SEQUENCE/SET-shaped members are constructed.
+ (NSData*)explicitTag:(uint8_t)n content:(NSData*)contentTLV;
+ (NSData*)implicitTag:(uint8_t)n constructed:(BOOL)constructed content:(NSData*)contentTLV;

// The bare DER length encoding for `length` (used when splicing by hand).
+ (NSData*)encodedLength:(NSUInteger)length;

@end

NS_ASSUME_NONNULL_END
