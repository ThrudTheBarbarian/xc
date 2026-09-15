#import "XTType.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTArrayType : XTType

@property(nonatomic, readonly) XTType* elementType;
/****************************************************************************\
|* 0 = size inferred from initialiser.
\****************************************************************************/
@property(nonatomic) NSUInteger elementCount;

/****************************************************************************\
|* Create an array type with a given element type and count.
|* @param elementType  The type of each element.
|* @param count        Number of elements; 0 means size is inferred from the initialiser.
|* @return A new array type.
\****************************************************************************/
+ (instancetype)arrayOfType:(XTType*)elementType count:(NSUInteger)count;

@end

NS_ASSUME_NONNULL_END
