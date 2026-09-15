//
//  XTCms.m — see XTCms.h.
//

#import "XTCms.h"
#import "XTDer.h"
#import "XTDerReader.h"
#import "XTCrypto.h"

// OIDs
static NSString* const OID_signedData = @"1.2.840.113549.1.7.2";
static NSString* const OID_data = @"1.2.840.113549.1.7.1";
static NSString* const OID_contentType = @"1.2.840.113549.1.9.3";
static NSString* const OID_messageDigest = @"1.2.840.113549.1.9.4";
static NSString* const OID_signingTime = @"1.2.840.113549.1.9.5";
static NSString* const OID_sha256 = @"2.16.840.1.101.3.4.2.1";
static NSString* const OID_rsaEncryption = @"1.2.840.113549.1.1.1";

// SHA-256 DigestInfo prefix (SEQ{ SEQ{ oid sha256, NULL }, OCTET(32) }).
static NSData* sha256DigestInfo(NSData* digest)
    {
    NSData* algo = [XTDer sequence:@[ [XTDer oid:OID_sha256], [XTDer null] ]];
    return [XTDer sequence:@[ algo, [XTDer octetString:digest] ]];
    }

@implementation XTCms

+ (nullable NSData*)signedDataForCodeDirectorySha256:(NSData*)cdHash
                                       signerCertDer:(NSData*)signerCertDer
                                            chainDer:(NSArray<NSData*>*)chainDer
                                          keyModulus:(NSData*)keyModulus
                                  keyPrivateExponent:(NSData*)keyD
                                         signingTime:(NSString*)signingTime
    {
    NSData *issuer = nil, *serial = nil;
    if (![XTDerReader certificate:signerCertDer issuerName:&issuer serialNumber:&serial])
        return nil;

    // ── signed attributes (three Attribute SEQUENCEs) ──
    NSData* attrContentType = [XTDer sequence:@[
        [XTDer oid:OID_contentType], [XTDer setOf:@[ [XTDer oid:OID_data] ]]
    ]];
    NSData* attrMsgDigest = [XTDer sequence:@[
        [XTDer oid:OID_messageDigest], [XTDer setOf:@[ [XTDer octetString:cdHash] ]]
    ]];
    NSData* attrSigningTime = [XTDer sequence:@[
        [XTDer oid:OID_signingTime], [XTDer setOf:@[ [XTDer generalizedTime:signingTime] ]]
    ]];

    NSArray<NSData*>* attrs = @[ attrContentType, attrMsgDigest, attrSigningTime ];

    // The value signed is the attributes encoded as a SET OF (tag 0x31).
    NSData* attrsForSigning = [XTDer setOf:attrs];
    NSData* attrsDigest = [XTCrypto sha256:attrsForSigning];
    NSData* signature = [XTCrypto rsaSignPKCS1:sha256DigestInfo(attrsDigest)
                                       modulus:keyModulus
                               privateExponent:keyD];
    if (!signature)
        return nil;

    // In the message the attributes appear under an IMPLICIT [0] (tag 0xA0),
    // same content bytes as the SET OF just signed.
    NSData* signedAttrsImplicit =
        [XTDer implicitTag:0
               constructed:YES
                   content:attrsForSigning];

    // ── SignerInfo ──
    NSData* sid = [XTDer sequence:@[ issuer, [XTDer tlv:0x02 content:serial] ]];
    NSData* digAlg = [XTDer sequence:@[ [XTDer oid:OID_sha256], [XTDer null] ]];
    NSData* sigAlg = [XTDer sequence:@[ [XTDer oid:OID_rsaEncryption], [XTDer null] ]];
    NSData* signerInfo = [XTDer sequence:@[
        [XTDer integerFromU64:1], // version (IssuerAndSerialNumber → 1)
        sid,
        digAlg,
        signedAttrsImplicit,
        sigAlg,
        [XTDer octetString:signature]
    ]];

    // ── SignedData ──
    NSMutableArray<NSData*>* certs = [NSMutableArray arrayWithObject:signerCertDer];
    [certs addObjectsFromArray:chainDer];
    NSData* certSet = [XTDer implicitTag:0 constructed:YES content:[XTDer sequence:certs]];
    // (a [0] IMPLICIT SET OF Certificate — concatenated cert TLVs, order kept)

    NSData* digAlgs = [XTDer setOf:@[ [XTDer sequence:@[ [XTDer oid:OID_sha256], [XTDer null] ]] ]];
    NSData* encap = [XTDer sequence:@[ [XTDer oid:OID_data] ]]; // detached: eContentType only
    NSData* signedData = [XTDer sequence:@[
        [XTDer integerFromU64:1], // version
        digAlgs,
        encap,
        certSet,
        [XTDer setOf:@[ signerInfo ]]
    ]];

    // ── ContentInfo ──
    NSData* content = [XTDer explicitTag:0 content:signedData];
    return [XTDer sequence:@[ [XTDer oid:OID_signedData], content ]];
    }

@end
