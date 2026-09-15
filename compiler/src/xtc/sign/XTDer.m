//
//  XTDer.m — see XTDer.h.
//

#import "XTDer.h"

@implementation XTDer

+ (NSData*)encodedLength:(NSUInteger)length
    {
    NSMutableData* d = [NSMutableData data];
    if (length < 0x80)
        {
        uint8_t b = (uint8_t)length;
        [d appendBytes:&b length:1];
        return d;
        }
    // Long form: 0x80 | number-of-length-bytes, then big-endian length.
    uint8_t tmp[8];
    int n = 0;
    NSUInteger v = length;
    while (v)
        {
        tmp[n++] = (uint8_t)(v & 0xFF);
        v >>= 8;
        }
    uint8_t lead = (uint8_t)(0x80 | n);
    [d appendBytes:&lead length:1];
    for (int i = n - 1; i >= 0; i--)
        [d appendBytes:&tmp[i] length:1];
    return d;
    }

+ (NSData*)tlv:(uint8_t)tag content:(NSData*)content
    {
    NSMutableData* d = [NSMutableData data];
    [d appendBytes:&tag length:1];
    [d appendData:[self encodedLength:content.length]];
    [d appendData:content];
    return d;
    }

+ (NSData*)integer:(NSData*)mag
    {
    // Strip leading zero bytes to a minimal magnitude, then re-add ONE 0x00 if
    // the top bit is set (keeps it positive) or if the whole thing was empty.
    const uint8_t* p = mag.bytes;
    NSUInteger n = mag.length;
    NSUInteger start = 0;
    while (start < n && p[start] == 0x00)
        start++;
    NSMutableData* content = [NSMutableData data];
    if (start == n)
        {
        uint8_t z = 0x00;
        [content appendBytes:&z length:1]; // INTEGER 0
        }
    else
        {
        if (p[start] & 0x80)
            {
            uint8_t z = 0x00;
            [content appendBytes:&z length:1];
            }
        [content appendBytes:p + start length:n - start];
        }
    return [self tlv:0x02 content:content];
    }

+ (NSData*)integerFromU64:(uint64_t)value
    {
    uint8_t be[8];
    for (int i = 0; i < 8; i++)
        be[i] = (uint8_t)(value >> (56 - 8 * i));
    return [self integer:[NSData dataWithBytes:be length:8]];
    }

+ (NSData*)boolean:(BOOL)value
    {
    uint8_t b = value ? 0xFF : 0x00;
    return [self tlv:0x01 content:[NSData dataWithBytes:&b length:1]];
    }

+ (NSData*)null
    {
    return [self tlv:0x05 content:[NSData data]];
    }

+ (NSData*)octetString:(NSData*)bytes
    {
    return [self tlv:0x04 content:bytes];
    }

+ (NSData*)bitString:(NSData*)bytes unusedBits:(uint8_t)unusedBits
    {
    NSMutableData* content = [NSMutableData data];
    [content appendBytes:&unusedBits length:1];
    [content appendData:bytes];
    return [self tlv:0x03 content:content];
    }

+ (NSData*)oid:(NSString*)dotted
    {
    NSArray<NSString*>* parts = [dotted componentsSeparatedByString:@"."];
    NSMutableData* content = [NSMutableData data];
    // First octet packs arcs 1 and 2: 40*arc1 + arc2.
    NSUInteger arc1 = (NSUInteger)[parts[0] integerValue];
    NSUInteger arc2 = (NSUInteger)[parts[1] integerValue];
    NSUInteger first = 40 * arc1 + arc2;
    // Base-128, big-endian, high bit set on all but the last octet.
    void (^emit)(NSUInteger) = ^(NSUInteger v) {
      uint8_t stack[10];
      int n = 0;
      stack[n++] = (uint8_t)(v & 0x7F);
      v >>= 7;
      while (v)
          {
          stack[n++] = (uint8_t)((v & 0x7F) | 0x80);
          v >>= 7;
          }
      for (int i = n - 1; i >= 0; i--)
          [content appendBytes:&stack[i] length:1];
    };
    emit(first);
    for (NSUInteger i = 2; i < parts.count; i++)
        emit((NSUInteger)[parts[i] integerValue]);
    return [self tlv:0x06 content:content];
    }

+ (NSData*)stringOfTag:(uint8_t)tag from:(NSString*)string
    {
    return [self tlv:tag content:[string dataUsingEncoding:NSUTF8StringEncoding]];
    }
+ (NSData*)utf8String:(NSString*)s
    {
    return [self stringOfTag:0x0C from:s];
    }
+ (NSData*)printableString:(NSString*)s
    {
    return [self stringOfTag:0x13 from:s];
    }
+ (NSData*)ia5String:(NSString*)s
    {
    return [self stringOfTag:0x16 from:s];
    }
+ (NSData*)utcTime:(NSString*)s
    {
    return [self stringOfTag:0x17 from:s];
    }
+ (NSData*)generalizedTime:(NSString*)s
    {
    return [self stringOfTag:0x18 from:s];
    }

+ (NSData*)concat:(NSArray<NSData*>*)elements
    {
    NSMutableData* d = [NSMutableData data];
    for (NSData* e in elements)
        [d appendData:e];
    return d;
    }

+ (NSData*)sequence:(NSArray<NSData*>*)elements
    {
    return [self tlv:0x30 content:[self concat:elements]];
    }

+ (NSData*)set:(NSArray<NSData*>*)elements
    {
    return [self tlv:0x31 content:[self concat:elements]];
    }

+ (NSData*)setOf:(NSArray<NSData*>*)elements
    {
    // DER SET OF: members sorted lexicographically by their full encoding,
    // shorter-is-smaller on a common prefix.
    NSArray<NSData*>* sorted = [elements sortedArrayUsingComparator:^(NSData* a, NSData* b) {
      const uint8_t *pa = a.bytes, *pb = b.bytes;
      NSUInteger na = a.length, nb = b.length, m = MIN(na, nb);
      for (NSUInteger i = 0; i < m; i++)
          {
          if (pa[i] != pb[i])
              return pa[i] < pb[i] ? NSOrderedAscending : NSOrderedDescending;
          }
      if (na != nb)
          return na < nb ? NSOrderedAscending : NSOrderedDescending;
      return NSOrderedSame;
    }];
    return [self tlv:0x31 content:[self concat:sorted]];
    }

+ (NSData*)explicitTag:(uint8_t)n content:(NSData*)contentTLV
    {
    return [self tlv:(uint8_t)(0xA0 | n) content:contentTLV];
    }

+ (NSData*)implicitTag:(uint8_t)n constructed:(BOOL)constructed content:(NSData*)contentTLV
    {
    // Replace the identifier octet of an existing TLV with [n] context-specific.
    NSAssert(contentTLV.length >= 1, @"empty TLV");
    const uint8_t* p = contentTLV.bytes;
    // Skip the old identifier and its length octets to find the value bytes.
    NSUInteger i = 1;
    uint8_t l0 = p[i++];
    NSUInteger vlen;
    if (l0 < 0x80)
        {
        vlen = l0;
        }
    else
        {
        int ln = l0 & 0x7F;
        vlen = 0;
        for (int k = 0; k < ln; k++)
            vlen = (vlen << 8) | p[i++];
        }
    NSData* value = [NSData dataWithBytes:p + i length:vlen];
    uint8_t tag = (uint8_t)(0x80 | n | (constructed ? 0x20 : 0x00));
    return [self tlv:tag content:value];
    }

@end
