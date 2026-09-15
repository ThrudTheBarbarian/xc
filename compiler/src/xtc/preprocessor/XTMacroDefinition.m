#import "XTMacroDefinition.h"

@implementation XTMacroDefinition

/****************************************************************************\
|* Designated initialiser for a macro definition. Sets isFunctionLike based
|* on whether parameters is non-nil, and isVarArgs based on whether the last
|* parameter is @"...".
|* @param name        The macro name.
|* @param parameters  Parameter names, or nil for object-like macros.
|* @param body        The macro body as raw text.
|* @return A new macro definition.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
                  parameters:(nullable NSArray<NSString*>*)parameters
                        body:(NSString*)body
    {
    self = [super init];
    if (self)
        {
        _name = [name copy];
        _parameters = [parameters copy];
        _body = [body copy];
        _isFunctionLike = (parameters != nil);
        _isVarArgs = (parameters != nil && [parameters.lastObject isEqualToString:@"..."]);
        }
    return self;
    }

@end
