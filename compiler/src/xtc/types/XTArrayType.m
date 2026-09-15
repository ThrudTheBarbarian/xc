#import "XTArrayType.h"

@implementation XTArrayType

/****************************************************************************\
|* Internal initialiser. Builds display name as "<type>[N]" or "<type>[]".
|* @param elementType  The type of each element.
|* @param count        Number of elements; 0 for unsized arrays.
|* @return A new array type.
\****************************************************************************/
- (instancetype)initWithElementType:(XTType*)elementType count:(NSUInteger)count
    {
    NSString* name;
    if (count > 0)
        {
        name = [NSString stringWithFormat:@"%@[%lu]", elementType.displayName, (unsigned long)count];
        }
    else
        {
        name = [NSString stringWithFormat:@"%@[]", elementType.displayName];
        }
    self = [super initWithKind:XTTypeKindArray displayName:name];
    if (self)
        {
        _elementType = elementType;
        _elementCount = count;
        }
    return self;
    }

/****************************************************************************\
|* Create an array type with a given element type and count.
|* @param elementType  The type of each element.
|* @param count        Number of elements; 0 means size is inferred from the initialiser.
|* @return A new array type.
\****************************************************************************/
+ (instancetype)arrayOfType:(XTType*)elementType count:(NSUInteger)count
    {
    return [[self alloc] initWithElementType:elementType count:count];
    }

/****************************************************************************\
|* Total byte size of the array (element width * count).
|* @return The total size in bytes.
\****************************************************************************/
- (NSUInteger)byteWidth
    {
    return _elementType.byteWidth * _elementCount;
    }

/****************************************************************************\
|* Arrays decay to pointers, so they are pointer-like.
|* @return YES.
\****************************************************************************/
- (BOOL)isPointerLike
    {
    return YES;
    }

@end
