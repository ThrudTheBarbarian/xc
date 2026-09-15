//
//  XTDerReader.m — see XTDerReader.h.
//

#import "XTDerReader.h"

@implementation XTDerReader
    {
    const uint8_t* _p;
    NSUInteger _len;
    NSUInteger _pos;
    NSData* _backing; // keep the bytes alive
    }

- (instancetype)initWithData:(NSData*)data
    {
    if ((self = [super init]))
        {
        _backing = data;
        _p = data.bytes;
        _len = data.length;
        _pos = 0;
        }
    return self;
    }

- (BOOL)atEnd
    {
    return _pos >= _len;
    }

// Parse tag + length at _pos; return NO on malformed. On success, *valueOff is
// the offset of the value, *valueLen its length, *nextPos the byte after it.
- (BOOL)peekTag:(uint8_t*)tag valueOff:(NSUInteger*)valueOff
       valueLen:(NSUInteger*)valueLen
        nextPos:(NSUInteger*)nextPos
    {
    NSUInteger i = _pos;
    if (i >= _len)
        return NO;
    uint8_t t = _p[i++];
    if (i >= _len)
        return NO;
    uint8_t l0 = _p[i++];
    NSUInteger vlen;
    if (l0 < 0x80)
        {
        vlen = l0;
        }
    else
        {
        int nb = l0 & 0x7F;
        if (nb == 0 || nb > 4 || i + nb > _len)
            return NO;
        vlen = 0;
        for (int k = 0; k < nb; k++)
            vlen = (vlen << 8) | _p[i++];
        }
    if (i + vlen > _len)
        return NO;
    *tag = t;
    *valueOff = i;
    *valueLen = vlen;
    *nextPos = i + vlen;
    return YES;
    }

- (BOOL)peekNextTag:(uint8_t*)tag
    {
    uint8_t t;
    NSUInteger vo, vl, np;
    if (![self peekTag:&t valueOff:&vo valueLen:&vl nextPos:&np])
        return NO;
    (void)vo;
    (void)vl;
    (void)np;
    if (tag)
        *tag = t;
    return YES;
    }

- (nullable NSData*)readTLV:(uint8_t*)tag
    {
    uint8_t t;
    NSUInteger vo, vl, np;
    if (![self peekTag:&t valueOff:&vo valueLen:&vl nextPos:&np])
        return nil;
    _pos = np;
    if (tag)
        *tag = t;
    return [NSData dataWithBytes:_p + vo length:vl];
    }

- (nullable NSData*)readElement
    {
    uint8_t t;
    NSUInteger vo, vl, np;
    if (![self peekTag:&t valueOff:&vo valueLen:&vl nextPos:&np])
        return nil;
    NSData* whole = [NSData dataWithBytes:_p + _pos length:np - _pos];
    _pos = np;
    return whole;
    }

- (nullable XTDerReader*)readConstructed:(uint8_t*)tag
    {
    uint8_t t;
    NSUInteger vo, vl, np;
    if (![self peekTag:&t valueOff:&vo valueLen:&vl nextPos:&np])
        return nil;
    if (!(t & 0x20))
        return nil; // not constructed
    _pos = np;
    if (tag)
        *tag = t;
    return [[XTDerReader alloc] initWithData:[NSData dataWithBytes:_p + vo length:vl]];
    }

+ (BOOL)certificate:(NSData*)certDer
         issuerName:(NSData* _Nullable* _Nonnull)issuerOut
       serialNumber:(NSData* _Nullable* _Nonnull)serialOut
    {
    *issuerOut = nil;
    *serialOut = nil;
    // Certificate ::= SEQ { tbsCertificate SEQ { [0] version?, serialNumber,
    //                       signatureAlg, issuer Name, validity, subject, ... }, ... }
    XTDerReader* top = [[XTDerReader alloc] initWithData:certDer];
    uint8_t t;
    XTDerReader* cert = [top readConstructed:&t]; // into Certificate
    if (!cert)
        return NO;
    XTDerReader* tbs = [cert readConstructed:&t]; // into tbsCertificate
    if (!tbs)
        return NO;
    // Optional [0] version.
    uint8_t vt;
    if ([tbs peekNextTag:&vt] && vt == 0xA0)
        {
        (void)[tbs readElement]; // skip version
        }
    uint8_t tg;
    NSData* serial = [tbs readTLV:&tg]; // serialNumber INTEGER
    if (!serial || tg != 0x02)
        return NO;
    (void)[tbs readElement];            // skip signatureAlg SEQ
    NSData* issuer = [tbs readElement]; // issuer Name SEQ (verbatim)
    if (!issuer)
        return NO;
    *serialOut = serial;
    *issuerOut = issuer;
    return YES;
    }

@end
