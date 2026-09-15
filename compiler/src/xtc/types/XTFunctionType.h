#import "XTType.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTFunctionType : XTType

@property(nonatomic, readonly) NSArray<XTType*>* returnTypes;
@property(nonatomic, readonly) NSArray<XTType*>* paramTypes;
@property(nonatomic, readonly) BOOL isVarArgs;

/****************************************************************************\
|* Create a function type describing a callable signature.
|* @param returnTypes  Array of return types (multiple for tuple returns).
|* @param paramTypes   Array of parameter types.
|* @param isVarArgs    YES if the function accepts variadic arguments.
|* @return A new function type with a 2-byte width (function pointer size).
\****************************************************************************/
+ (instancetype)functionWithReturnTypes:(NSArray<XTType*>*)returnTypes
                             paramTypes:(NSArray<XTType*>*)paramTypes
                              isVarArgs:(BOOL)isVarArgs;

@end

NS_ASSUME_NONNULL_END
