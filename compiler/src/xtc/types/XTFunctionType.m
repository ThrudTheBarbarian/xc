#import "XTFunctionType.h"

@implementation XTFunctionType

/****************************************************************************\
|* Internal initialiser. Builds a display name like "retType(paramType,...)".
|* @param returnTypes  Array of return types.
|* @param paramTypes   Array of parameter types.
|* @param isVarArgs    YES if variadic.
|* @return A new function type.
\****************************************************************************/
- (instancetype)initWithReturnTypes:(NSArray<XTType*>*)returnTypes
                         paramTypes:(NSArray<XTType*>*)paramTypes
                          isVarArgs:(BOOL)isVarArgs
    {
    NSMutableString* name = [NSMutableString string];
    NSArray<NSString*>* retNames = [returnTypes valueForKey:@"displayName"];
    [name appendString:[retNames componentsJoinedByString:@","]];
    [name appendString:@"("];
    NSArray<NSString*>* paramNames = [paramTypes valueForKey:@"displayName"];
    [name appendString:[paramNames componentsJoinedByString:@","]];
    if (isVarArgs)
        [name appendString:@",..."];
    [name appendString:@")"];

    self = [super initWithKind:XTTypeKindFunction displayName:name];
    if (self)
        {
        _returnTypes = [returnTypes copy];
        _paramTypes = [paramTypes copy];
        _isVarArgs = isVarArgs;
        }
    return self;
    }

/****************************************************************************\
|* Create a function type describing a callable signature.
|* @param returnTypes  Array of return types (multiple for tuple returns).
|* @param paramTypes   Array of parameter types.
|* @param isVarArgs    YES if the function accepts variadic arguments.
|* @return A new function type with a 2-byte width (function pointer size).
\****************************************************************************/
+ (instancetype)functionWithReturnTypes:(NSArray<XTType*>*)returnTypes
                             paramTypes:(NSArray<XTType*>*)paramTypes
                              isVarArgs:(BOOL)isVarArgs
    {
    return [[self alloc] initWithReturnTypes:returnTypes paramTypes:paramTypes isVarArgs:isVarArgs];
    }

/****************************************************************************\
|* Function pointer size is always 2 bytes (16-bit address).
|* @return 2.
\****************************************************************************/
// function pointer size
- (NSUInteger)byteWidth
    {
    return 2;
    }

@end
