#import "XTDwarfInterface.h"

@implementation XTDwarfFunction

- (instancetype)initWithName:(NSString*)name
                  returnType:(XTType*)returnType
                  paramTypes:(NSArray<XTType*>*)paramTypes
                  paramNames:(NSArray<NSString*>*)paramNames
                   isVarArgs:(BOOL)isVarArgs
    {
    self = [super init];
    if (self)
        {
        _name = [name copy];
        _returnType = returnType;
        _paramTypes = [paramTypes copy];
        _paramNames = [paramNames copy];
        _isVarArgs = isVarArgs;
        }
    return self;
    }

- (NSString*)description
    {
    NSMutableArray<NSString*>* parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < _paramTypes.count; i++)
        {
        NSString* nm = (i < _paramNames.count) ? _paramNames[i] : @"";
        if (nm.length)
            {
            [parts addObject:[NSString stringWithFormat:@"%@ %@", _paramTypes[i].displayName, nm]];
            }
        else
            {
            [parts addObject:_paramTypes[i].displayName];
            }
        }
    if (_isVarArgs)
        [parts addObject:@"..."];
    return [NSString stringWithFormat:@"%@ %@(%@)",
                                      _returnType.displayName, _name, [parts componentsJoinedByString:@", "]];
    }

@end

@implementation XTDwarfInterface

- (instancetype)initWithSoname:(NSString*)soname
                       exports:(NSSet<NSString*>*)exports
                     functions:(NSArray<XTDwarfFunction*>*)functions
                         types:(NSDictionary<NSString*, XTType*>*)types
    {
    return [self initWithSoname:soname
                        exports:exports
                      functions:functions
                          types:types
                  enumConstants:@{}];
    }

- (instancetype)initWithSoname:(NSString*)soname
                       exports:(NSSet<NSString*>*)exports
                     functions:(NSArray<XTDwarfFunction*>*)functions
                         types:(NSDictionary<NSString*, XTType*>*)types
                 enumConstants:(NSDictionary<NSString*, NSNumber*>*)enumConstants
    {
    self = [super init];
    if (self)
        {
        _soname = [soname copy];
        _exports = [exports copy];
        _functions = [functions copy];
        _types = [types copy];
        _enumConstants = [enumConstants copy];
        NSMutableDictionary<NSString*, XTDwarfFunction*>* byName = [NSMutableDictionary dictionary];
        for (XTDwarfFunction* fn in functions)
            byName[fn.name] = fn;
        _functionsByName = [byName copy];
        }
    return self;
    }

@end
