#import "XTFloatEncoding.h"
#import <math.h>

@implementation XTFloatEncoding

+ (NSData*)ieeeDataForDouble:(double)value width:(NSUInteger)width
    {
    uint8_t b[8];
    if (width == 8)
        {
        uint64_t bits;
        memcpy(&bits, &value, 8);
        for (int i = 0; i < 8; i++)
            b[i] = (uint8_t)((bits >> (8 * i)) & 0xFF);
        return [NSData dataWithBytes:b length:8];
        }
    float f = (float)value;
    uint32_t bits;
    memcpy(&bits, &f, 4);
    for (int i = 0; i < 4; i++)
        b[i] = (uint8_t)((bits >> (8 * i)) & 0xFF);
    return [NSData dataWithBytes:b length:4];
    }

+ (double)doubleFromIEEEData:(NSData*)data
    {
    const uint8_t* p = data.bytes;
    if (data.length >= 8)
        {
        uint64_t bits = 0;
        for (int i = 0; i < 8; i++)
            bits |= ((uint64_t)p[i]) << (8 * i);
        double v;
        memcpy(&v, &bits, 8);
        return v;
        }
    if (data.length >= 4)
        {
        uint32_t bits = 0;
        for (int i = 0; i < 4; i++)
            bits |= ((uint32_t)p[i]) << (8 * i);
        float f;
        memcpy(&f, &bits, 4);
        return (double)f;
        }
    return 0.0;
    }

/****************************************************************************\
|* Encode a C double into the 5-byte xtc float format. Handles NaN, infinity,
|* zero, overflow, and underflow as special flag bits in byte 0.
|* @param value  The double-precision value to encode.
|* @return A 5-byte NSData containing the encoded representation.
\****************************************************************************/
+ (NSData*)encodeDouble:(double)value
    {
    uint8_t bytes[5] = {0, 0, 0, 0, 0};

    if (isnan(value))
        {
        bytes[0] |= 0x08; // NaN flag
        return [NSData dataWithBytes:bytes length:5];
        }

    if (isinf(value))
        {
        bytes[0] |= 0x20; // infinity flag
        if (value < 0.0)
            bytes[0] |= 0x01; // sign → -∞
        return [NSData dataWithBytes:bytes length:5];
        }

    if (value < 0.0)
        {
        bytes[0] |= 0x01; // sign
        value = -value;
        }

    if (value == 0.0)
        {
        bytes[0] |= 0x10; // zero flag
        return [NSData dataWithBytes:bytes length:5];
        }

    // Extract binary exponent and normalise to [1.0, 2.0)
    int exponent;
    double mantissa = frexp(value, &exponent);
    // frexp returns mantissa in [0.5, 1.0), so adjust to [1.0, 2.0)
    mantissa *= 2.0;
    exponent -= 1;

    // Check for overflow / underflow relative to int8 exponent range
    if (exponent > 127)
        {
        bytes[0] |= 0x04; // overflow
        return [NSData dataWithBytes:bytes length:5];
        }
    if (exponent < -128)
        {
        bytes[0] |= 0x02; // underflow
        return [NSData dataWithBytes:bytes length:5];
        }

    bytes[1] = (uint8_t)(int8_t)exponent;

    // Extract 24-bit mantissa (strip implicit leading 1)
    double fracPart = mantissa - 1.0;
    uint32_t mantissaBits = (uint32_t)(fracPart * (double)(1 << 24));
    bytes[2] = (mantissaBits >> 16) & 0xFF;
    bytes[3] = (mantissaBits >> 8) & 0xFF;
    bytes[4] = mantissaBits & 0xFF;

    return [NSData dataWithBytes:bytes length:5];
    }

/****************************************************************************\
|* Encode a C double into the 8-byte xtc double format. Same flag / exponent
|* layout as the 5-byte float, but with a 48-bit mantissa (bytes 2-7,
|* big-endian) for ~14.5 significant decimal digits.
|* @param value  The double-precision value to encode.
|* @return An 8-byte NSData containing the encoded representation.
\****************************************************************************/
+ (NSData*)encodeDoubleDouble:(double)value
    {
    uint8_t bytes[8] = {0, 0, 0, 0, 0, 0, 0, 0};

    if (isnan(value))
        {
        bytes[0] |= 0x08;
        return [NSData dataWithBytes:bytes length:8];
        }

    if (isinf(value))
        {
        bytes[0] |= 0x20;
        if (value < 0.0)
            bytes[0] |= 0x01;
        return [NSData dataWithBytes:bytes length:8];
        }

    if (value < 0.0)
        {
        bytes[0] |= 0x01;
        value = -value;
        }

    if (value == 0.0)
        {
        bytes[0] |= 0x10;
        return [NSData dataWithBytes:bytes length:8];
        }

    int exponent;
    double mantissa = frexp(value, &exponent);
    mantissa *= 2.0;
    exponent -= 1;

    if (exponent > 127)
        {
        bytes[0] |= 0x04;
        return [NSData dataWithBytes:bytes length:8];
        }
    if (exponent < -128)
        {
        bytes[0] |= 0x02;
        return [NSData dataWithBytes:bytes length:8];
        }

    bytes[1] = (uint8_t)(int8_t)exponent;

    double fracPart = mantissa - 1.0;
    uint64_t mantissaBits = (uint64_t)(fracPart * (double)(1ULL << 48));
    bytes[2] = (uint8_t)((mantissaBits >> 40) & 0xFF);
    bytes[3] = (uint8_t)((mantissaBits >> 32) & 0xFF);
    bytes[4] = (uint8_t)((mantissaBits >> 24) & 0xFF);
    bytes[5] = (uint8_t)((mantissaBits >> 16) & 0xFF);
    bytes[6] = (uint8_t)((mantissaBits >> 8) & 0xFF);
    bytes[7] = (uint8_t)(mantissaBits & 0xFF);

    return [NSData dataWithBytes:bytes length:8];
    }

/****************************************************************************\
|* Decode the 5-byte xtc float format back to a C double (for constant
|* folding). NaN, overflow, and underflow are handled via flag bits.
|* @param data  A 5-byte NSData in the xtc float format.
|* @return The decoded double-precision value.
\****************************************************************************/
+ (double)decodeData:(NSData*)data
    {
    const uint8_t* bytes = data.bytes;

    if (bytes[0] & 0x08)
        return NAN;
    if (bytes[0] & 0x20)
        return (bytes[0] & 0x01) ? -INFINITY : INFINITY;
    if (bytes[0] & 0x04)
        return INFINITY;
    if (bytes[0] & 0x02)
        return 0.0;
    if (bytes[0] & 0x10)
        return 0.0;

    int8_t exponent = (int8_t)bytes[1];
    uint32_t mantissaBits = ((uint32_t)bytes[2] << 16) |
                            ((uint32_t)bytes[3] << 8) |
                            (uint32_t)bytes[4];

    double mantissa = 1.0 + (double)mantissaBits / (double)(1 << 24);
    double result = ldexp(mantissa, exponent);

    if (bytes[0] & 0x01)
        result = -result;
    return result;
    }

/****************************************************************************\
|* Decode the 8-byte xtc double format back to a C double (for constant
|* folding). NaN, overflow, and underflow are handled via flag bits.
|* @param data  An 8-byte NSData in the xtc double format.
|* @return The decoded double-precision value.
\****************************************************************************/
+ (double)decodeDoubleData:(NSData*)data
    {
    const uint8_t* bytes = data.bytes;

    if (bytes[0] & 0x08)
        return NAN;
    if (bytes[0] & 0x20)
        return (bytes[0] & 0x01) ? -INFINITY : INFINITY;
    if (bytes[0] & 0x04)
        return INFINITY;
    if (bytes[0] & 0x02)
        return 0.0;
    if (bytes[0] & 0x10)
        return 0.0;

    int8_t exponent = (int8_t)bytes[1];
    uint64_t mantissaBits = ((uint64_t)bytes[2] << 40) |
                            ((uint64_t)bytes[3] << 32) |
                            ((uint64_t)bytes[4] << 24) |
                            ((uint64_t)bytes[5] << 16) |
                            ((uint64_t)bytes[6] << 8) |
                            (uint64_t)bytes[7];

    double mantissa = 1.0 + (double)mantissaBits / (double)(1ULL << 48);
    double result = ldexp(mantissa, exponent);

    if (bytes[0] & 0x01)
        result = -result;
    return result;
    }

/****************************************************************************\
|* Check whether the encoded value represents NaN (bit 3 of byte 0).
|* @param data  A 5-byte NSData in the xtc float format.
|* @return YES if the NaN flag is set.
\****************************************************************************/
+ (BOOL)isNaN:(NSData*)data
    {
    return (((const uint8_t*)data.bytes)[0] & 0x08) != 0;
    }

/****************************************************************************\
|* Check whether the encoded value represents an overflow (bit 2 of byte 0).
|* @param data  A 5-byte NSData in the xtc float format.
|* @return YES if the overflow flag is set.
\****************************************************************************/
+ (BOOL)isOverflow:(NSData*)data
    {
    return (((const uint8_t*)data.bytes)[0] & 0x04) != 0;
    }

/****************************************************************************\
|* Check whether the encoded value represents underflow (bit 1 of byte 0).
|* @param data  A 5-byte NSData in the xtc float format.
|* @return YES if the underflow flag is set.
\****************************************************************************/
+ (BOOL)isUnderflow:(NSData*)data
    {
    return (((const uint8_t*)data.bytes)[0] & 0x02) != 0;
    }

@end
