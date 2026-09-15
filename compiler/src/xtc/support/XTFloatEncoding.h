#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* 5-byte float format (flags+exp+24-bit mantissa) and 8-byte double format
|* (flags+exp+48-bit mantissa). Both share byte 0 (flags) and byte 1 (exp):
|*   Byte 0, bit 0: sign (1 = negative)
|*   Byte 0, bit 1: underflow flag
|*   Byte 0, bit 2: overflow flag
|*   Byte 0, bit 3: NaN flag
|*   Byte 0, bit 4: zero flag (value is +0; other bytes ignored)
|*   Byte 0, bit 5: infinity flag
|*   Byte 1: signed exponent (two's complement, base-2)
|*   Bytes 2-4 (float) or 2-7 (double): big-endian mantissa, normalised with
|*                                      an implicit leading 1.
|* Without the zero flag, an all-zero encoding is indistinguishable from 1.0;
|* the flag breaks that tie and lets arithmetic routines recognise zero
|* operands up front.
\****************************************************************************/

@interface XTFloatEncoding : NSObject

/****************************************************************************\
|* IEEE-754 bytes, little-endian: 8 for a double, 4 for a single. This is what
|* a float LITERAL carries from the lexer to the lowering now, and it is the
|* only lossless choice — the formats below round to 24 or 48 mantissa bits,
|* and the value both starts (strtod) and ends (the backends, every one of
|* which emits IEEE) as a 53-bit double. A `d` literal used to lose five bits
|* on the way through for no reason at all.
\****************************************************************************/
+ (NSData*)ieeeDataForDouble:(double)value width:(NSUInteger)width;

/****************************************************************************\
|* The inverse: 8 bytes → the double, 4 bytes → the single widened to double.
\****************************************************************************/
+ (double)doubleFromIEEEData:(NSData*)data;

/****************************************************************************\
|* Encode a C double into the 5-byte xtc float format.
|* Returns a 5-byte NSData.
\****************************************************************************/
+ (NSData*)encodeDouble:(double)value;

/****************************************************************************\
|* Encode a C double into the 8-byte xtc double format (48-bit mantissa).
|* Returns an 8-byte NSData.
\****************************************************************************/
+ (NSData*)encodeDoubleDouble:(double)value;

/****************************************************************************\
|* Decode the 5-byte xtc float format back to a C double (for constant folding).
\****************************************************************************/
+ (double)decodeData:(NSData*)data;

/****************************************************************************\
|* Decode the 8-byte xtc double format back to a C double (for constant
|* folding).
\****************************************************************************/
+ (double)decodeDoubleData:(NSData*)data;

/****************************************************************************\
|* Returns YES if the encoded value represents NaN.
\****************************************************************************/
+ (BOOL)isNaN:(NSData*)data;
/****************************************************************************\
|* Returns YES if the encoded value represents an overflow.
\****************************************************************************/
+ (BOOL)isOverflow:(NSData*)data;
/****************************************************************************\
|* Returns YES if the encoded value represents underflow.
\****************************************************************************/
+ (BOOL)isUnderflow:(NSData*)data;

@end

NS_ASSUME_NONNULL_END
