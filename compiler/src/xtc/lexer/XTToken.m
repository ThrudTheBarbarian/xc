#import "XTToken.h"

@implementation XTToken

/****************************************************************************\
|* Designated initialiser for a basic token (no numeric payload).
|* @param type      The token type enum value.
|* @param value     The source text of the token.
|* @param location  Source location of the token.
|* @return A new token.
\****************************************************************************/
- (instancetype)initWithType:(XTTokenType)type
                       value:(NSString*)value
                    location:(XTSourceLocation*)location
    {
    self = [super init];
    if (self)
        {
        _type = type;
        _value = [value copy];
        _location = location;
        _intValue = 0;
        _floatData = nil;
        }
    return self;
    }

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
                    location:(XTSourceLocation*)location
    {
    self = [self initWithType:type value:value location:location];
    if (self)
        {
        _intValue = intValue;
        }
    return self;
    }

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
                    location:(XTSourceLocation*)location
    {
    self = [self initWithType:type value:value location:location];
    if (self)
        {
        _floatData = floatData;
        }
    return self;
    }

/****************************************************************************\
|* Convenience factory for a basic token with no numeric payload.
|* @param type      The token type enum value.
|* @param value     The source text of the token.
|* @param location  Source location of the token.
|* @return A new autoreleased token.
\****************************************************************************/
+ (instancetype)tokenWithType:(XTTokenType)type
                        value:(NSString*)value
                     location:(XTSourceLocation*)location
    {
    return [[self alloc] initWithType:type value:value location:location];
    }

/****************************************************************************\
|* Returns YES if this token is a type keyword (i8, u8, ..., auto).
|* @return YES for type keywords, NO otherwise.
\****************************************************************************/
- (BOOL)isTypeKeyword
    {
    return (_type == XTTokenI8 || _type == XTTokenU8 ||
            _type == XTTokenI16 || _type == XTTokenU16 ||
            _type == XTTokenI32 || _type == XTTokenU32 ||
            _type == XTTokenI64 || _type == XTTokenU64 ||
            _type == XTTokenBool || _type == XTTokenFloat ||
            _type == XTTokenDouble || _type == XTTokenVoid ||
            _type == XTTokenPointer || _type == XTTokenString ||
            _type == XTTokenAuto);
    }

/****************************************************************************\
|* Returns YES if this token is any assignment operator (=, +=, -=, etc.).
|* @return YES for assignment operators, NO otherwise.
\****************************************************************************/
- (BOOL)isAssignmentOperator
    {
    return (_type == XTTokenAssign || _type == XTTokenPlusAssign ||
            _type == XTTokenMinusAssign || _type == XTTokenStarAssign ||
            _type == XTTokenSlashAssign || _type == XTTokenPercentAssign ||
            _type == XTTokenAmpAssign || _type == XTTokenPipeAssign ||
            _type == XTTokenCaretAssign || _type == XTTokenShlAssign ||
            _type == XTTokenShrAssign || _type == XTTokenRolAssign ||
            _type == XTTokenRorAssign);
    }

/****************************************************************************\
|* Human-readable description including type, value, and location.
|* @return A formatted string like "XTToken(Identifier, 'foo', file:1:2)".
\****************************************************************************/
- (NSString*)description
    {
    return [NSString stringWithFormat:@"XTToken(%@, '%@', %@)",
                                      XTTokenTypeName(_type), _value, _location];
    }

@end
