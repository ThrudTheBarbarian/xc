#import "XTTypeTable.h"
#import "XTStructType.h"

@interface XTTypeTable ()
@property(nonatomic) NSMutableDictionary<NSString*, XTType*>* table;
@end

@implementation XTTypeTable

/****************************************************************************\
|* Initialise the type table with all built-in scalar types pre-registered.
|* @return A new type table.
\****************************************************************************/
- (instancetype)init
    {
    self = [super init];
    if (self)
        {
        _table = [NSMutableDictionary dictionary];
        // Pre-register scalars
        _table[@"i8"] = [XTType i8Type];
        _table[@"u8"] = [XTType u8Type];
        _table[@"i16"] = [XTType i16Type];
        _table[@"u16"] = [XTType u16Type];
        _table[@"i32"] = [XTType i32Type];
        _table[@"u32"] = [XTType u32Type];
        _table[@"i64"] = [XTType i64Type];
        _table[@"u64"] = [XTType u64Type];
        _table[@"bool"] = [XTType boolType];
        _table[@"float"] = [XTType floatType];
        _table[@"double"] = [XTType doubleType];
        _table[@"void"] = [XTType voidType];
        _table[@"pointer"] = [XTType pointerType];
        _table[@"auto"] = [XTType autoType];
        // 'string' is u8@ — register as pointer to u8
        _table[@"string"] = [XTType u8Type]; // handled specially by parser
        // PR7: universal Object base class. Pre-register as a class
        // marker so `Object@` parses even before any user-land
        // declaration — sema wires the decl node up in
        // resolveClassHierarchy and makes every parentless class
        // implicitly descend from Object.
        _table[@"Object"] = [[XTType alloc] initWithKind:XTTypeKindClass
                                             displayName:@"Object"];
        }
    return self;
    }

/****************************************************************************\
|* Register a named type (struct, enum, class, typedef alias).
|* @param type  The type object to register.
|* @param name  The name to register it under.
\****************************************************************************/
- (NSArray*)allStructTypes
    {
    NSMutableArray* out = [NSMutableArray array];
    for (NSString* k in self.table)
        {
        XTType* t = self.table[k];
        if ([t isKindOfClass:[XTStructType class]])
            [out addObject:t];
        }
    return out;
    }

- (void)registerType:(XTType*)type forName:(NSString*)name
    {
    _table[name] = type;
    }

/****************************************************************************\
|* Look up a type by name.
|* @param name  The type name to search for.
|* @return The matching type, or nil if not found.
\****************************************************************************/
- (nullable XTType*)typeForName:(NSString*)name
    {
    return _table[name];
    }

/****************************************************************************\
|* Check whether a name refers to a known type.
|* @param name  The name to check.
|* @return YES if the name is registered in the table.
\****************************************************************************/
- (BOOL)isTypeName:(NSString*)name
    {
    return _table[name] != nil;
    }

/****************************************************************************\
|* Look up a scalar type by its keyword name (e.g. "i8", "u16", "float").
|* @param keyword  The type keyword string.
|* @return The matching scalar type, or nil if not a known keyword.
\****************************************************************************/
- (nullable XTType*)scalarTypeForKeyword:(NSString*)keyword
    {
    return _table[keyword];
    }

@end
