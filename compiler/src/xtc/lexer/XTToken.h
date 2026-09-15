#import <Foundation/Foundation.h>
#import "XTTokenType.h"
#import "XTSourceLocation.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTToken : NSObject

@property(nonatomic, readonly) XTTokenType type;
/****************************************************************************\
|* String value of the token as it appeared in source.
\****************************************************************************/
@property(nonatomic, readonly) NSString* value;
/****************************************************************************\
|* For float literals, the 5-byte encoded form.
\****************************************************************************/
@property(nonatomic, readonly, nullable) NSData* floatData;
/****************************************************************************\
|* For integer literals, the parsed value.
\****************************************************************************/
@property(nonatomic, readonly) int64_t intValue;
@property(nonatomic, readonly) XTSourceLocation* location;

/****************************************************************************\
|* Designated initialiser for a basic token (no numeric payload).
|* @param type      The token type enum value.
|* @param value     The source text of the token.
|* @param location  Source location of the token.
|* @return A new token.
\****************************************************************************/
- (instancetype)initWithType:(XTTokenType)type
                       value:(NSString*)value
                    location:(XTSourceLocation*)location NS_DESIGNATED_INITIALIZER;

/****************************************************************************\
|* Create a token carrying a parsed integer value (for int/char literals).
|* @param type      The token type (e.g. XTTokenIntLiteral).
|* @param value     The source text of the literal.
|* @param intValue  The parsed 64-bit integer value.
|* @param location  Source location of the literal.
|* @return A new token with the intValue field populated.
\****************************************************************************/
- (instancetype)initWithType:(XTTokenType)type
                       value:(NSString*)value
                    intValue:(int64_t)intValue
                    location:(XTSourceLocation*)location;

/****************************************************************************\
|* Create a token carrying encoded float data (for float literals).
|* @param type       The token type (XTTokenFloatLiteral).
|* @param value      The source text of the literal.
|* @param floatData  The literal's IEEE-754 bytes, little-endian: 8 for a
|*                   `d` literal, 4 otherwise.
|* @param location   Source location of the literal.
|* @return A new token with the floatData field populated.
\****************************************************************************/
- (instancetype)initWithType:(XTTokenType)type
                       value:(NSString*)value
                   floatData:(NSData*)floatData
                    location:(XTSourceLocation*)location;

/****************************************************************************\
|* Convenience factory for a basic token with no numeric payload.
|* @param type      The token type enum value.
|* @param value     The source text of the token.
|* @param location  Source location of the token.
|* @return A new autoreleased token.
\****************************************************************************/
+ (instancetype)tokenWithType:(XTTokenType)type
                        value:(NSString*)value
                     location:(XTSourceLocation*)location;

/****************************************************************************\
|* Returns YES if this token is a type keyword (i8, u8, ..., auto).
|* @return YES for type keywords, NO otherwise.
\****************************************************************************/
- (BOOL)isTypeKeyword;
/****************************************************************************\
|* Returns YES if this token is any assignment operator (=, +=, -=, etc.).
|* @return YES for assignment operators, NO otherwise.
\****************************************************************************/
- (BOOL)isAssignmentOperator;
/****************************************************************************\
|* Human-readable description including type, value, and location.
|* @return A formatted string like "XTToken(Identifier, 'foo', file:1:2)".
\****************************************************************************/
- (NSString*)description;

@end

NS_ASSUME_NONNULL_END
