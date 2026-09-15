#import "XTType.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTEnumType : XTType

@property(nonatomic, readonly) NSString* enumName;
/****************************************************************************\
|* Maps member name → integer value.
\****************************************************************************/
@property(nonatomic, readonly) NSDictionary<NSString*, NSNumber*>* members;
/****************************************************************************\
|* The underlying scalar type (smallest that fits all values).
\****************************************************************************/
@property(nonatomic, readonly) XTType* underlyingType;

/****************************************************************************\
|* Create an enum type. The underlying scalar type is automatically chosen
|* as the smallest integer type that can hold all member values.
|* @param name     The enum tag name.
|* @param members  Dictionary mapping member names to integer values.
|* @return A new enum type.
\****************************************************************************/
+ (instancetype)enumNamed:(NSString*)name
                  members:(NSDictionary<NSString*, NSNumber*>*)members;

/****************************************************************************\
|* Fill in a placeholder enum's members after the fact. Used by the
|* parser's forward-reference pre-scan (see XTStructType.replaceFields).
\****************************************************************************/
- (void)replaceMembers:(NSDictionary<NSString*, NSNumber*>*)members;

/****************************************************************************\
|* Look up the integer value for a named enum member.
|* @param memberName  The member name to look up.
|* @return The integer value as an NSNumber, or nil if not found.
\****************************************************************************/
- (nullable NSNumber*)valueForMember:(NSString*)memberName;

@end

NS_ASSUME_NONNULL_END
