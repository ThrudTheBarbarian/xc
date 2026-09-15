#import "XTEnumType.h"

@implementation XTEnumType

/****************************************************************************\
|* Internal initialiser. Determines the smallest underlying integer type that
|* fits all member values (u8/u16/u32 for non-negative, i8/i16/i32 otherwise).
|* @param name     The enum tag name.
|* @param members  Dictionary mapping member names to integer values.
|* @return A new enum type.
\****************************************************************************/
- (instancetype)initWithEnumName:(NSString*)name
                         members:(NSDictionary<NSString*, NSNumber*>*)members
    {
    // Determine smallest underlying type
    int64_t minVal = INT64_MAX, maxVal = INT64_MIN;
    for (NSNumber* n in members.allValues)
        {
        int64_t v = n.longLongValue;
        if (v < minVal)
            minVal = v;
        if (v > maxVal)
            maxVal = v;
        }
    XTType* underlying;
    if (minVal >= 0)
        {
        if (maxVal <= 255)
            underlying = [XTType u8Type];
        else if (maxVal <= 65535)
            underlying = [XTType u16Type];
        else
            underlying = [XTType u32Type];
        }
    else
        {
        if (minVal >= -128 && maxVal <= 127)
            underlying = [XTType i8Type];
        else if (minVal >= -32768 && maxVal <= 32767)
            underlying = [XTType i16Type];
        else
            underlying = [XTType i32Type];
        }

    self = [super initWithKind:XTTypeKindEnum displayName:name];
    if (self)
        {
        _enumName = [name copy];
        _members = [members copy];
        _underlyingType = underlying;
        }
    return self;
    }

/****************************************************************************\
|* Create an enum type. The underlying scalar type is automatically chosen
|* as the smallest integer type that can hold all member values.
|* @param name     The enum tag name.
|* @param members  Dictionary mapping member names to integer values.
|* @return A new enum type.
\****************************************************************************/
+ (instancetype)enumNamed:(NSString*)name
                  members:(NSDictionary<NSString*, NSNumber*>*)members
    {
    return [[self alloc] initWithEnumName:name members:members];
    }

/****************************************************************************\
|* Fill in a placeholder enum's members after the fact. Recomputes the
|* underlying type. Used by the parser's forward-reference pre-scan.
|* @param members  Dictionary mapping member names to integer values.
\****************************************************************************/
- (void)replaceMembers:(NSDictionary<NSString*, NSNumber*>*)members
    {
    int64_t minVal = INT64_MAX, maxVal = INT64_MIN;
    for (NSNumber* n in members.allValues)
        {
        int64_t v = n.longLongValue;
        if (v < minVal)
            minVal = v;
        if (v > maxVal)
            maxVal = v;
        }
    XTType* underlying;
    if (members.count == 0)
        {
        underlying = [XTType u8Type];
        }
    else if (minVal >= 0)
        {
        if (maxVal <= 255)
            underlying = [XTType u8Type];
        else if (maxVal <= 65535)
            underlying = [XTType u16Type];
        else
            underlying = [XTType u32Type];
        }
    else
        {
        if (minVal >= -128 && maxVal <= 127)
            underlying = [XTType i8Type];
        else if (minVal >= -32768 && maxVal <= 32767)
            underlying = [XTType i16Type];
        else
            underlying = [XTType i32Type];
        }
    _members = [members copy];
    _underlyingType = underlying;
    }

/****************************************************************************\
|* Byte width of the enum, delegated to the underlying integer type.
|* @return The byte width (1, 2, or 4).
\****************************************************************************/
- (NSUInteger)byteWidth
    {
    return _underlyingType.byteWidth;
    }

/****************************************************************************\
|* Enums are integer-like for type compatibility purposes.
|* @return YES.
\****************************************************************************/
- (BOOL)isInteger
    {
    return YES;
    }

/****************************************************************************\
|* Look up the integer value for a named enum member.
|* @param memberName  The member name to look up.
|* @return The integer value as an NSNumber, or nil if not found.
\****************************************************************************/
- (nullable NSNumber*)valueForMember:(NSString*)memberName
    {
    return _members[memberName];
    }

@end
