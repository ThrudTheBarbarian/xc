// XTIRSymbol.m
#import "XTIRSymbol.h"
#import "XTIRFunction.h"
#import "XTIRType.h"
#import "XTIRLayout.h"

#pragma mark - XTIRClobberSet

@implementation XTIRClobberSet
- (instancetype)initWithClobberedNames:(NSArray<NSString*>*)names
    {
    self = [super init];
    if (self)
        {
        _clobberedNames = [names copy];
        }
    return self;
    }
@end

#pragma mark - XTIRSymbol

@interface XTIRSymbol ()
// Redeclared readwrite internally for construction.
@property(nonatomic, readwrite) XTIRSymbolKind kind;
@property(nonatomic, readwrite, copy) NSString* name;
@property(nonatomic, readwrite, nullable) XTIRFunction* function;
@property(nonatomic, readwrite, nullable) XTIRType* functionType;
@property(nonatomic, readwrite, nullable) XTIRType* globalType;
@property(nonatomic, readwrite) BOOL volatileAccess;
@property(nonatomic, readwrite) BOOL escapes;
@property(nonatomic, readwrite) BOOL taskLocal;
@property(nonatomic, readwrite, nullable) XTIRClobberSet* clobberSet;
@property(nonatomic, readwrite) BOOL mayAlloc;
@property(nonatomic, readwrite) BOOL mayThrow;
@property(nonatomic, readwrite) uint16_t address;
@property(nonatomic, readwrite, nullable) NSData* stringBytes;
@property(nonatomic, readwrite, nullable) XTIRLayout* vtableLayout;
@end

@implementation XTIRSymbol

- (BOOL)isExternalGlobal
    {
    return [self.attributes[@"extern"] boolValue];
    }
- (void)setIsExternalGlobal:(BOOL)v
    {
    // Only ever ADD the key, never write `extern: false`. Attributes are printed into
    // the IR text, and stamping a default onto every global rewrites every golden .ir
    // in the tree for no reason.
    NSMutableDictionary* a = [self.attributes mutableCopy] ?: [NSMutableDictionary dictionary];
    if (v)
        a[@"extern"] = @YES;
    else
        [a removeObjectForKey:@"extern"];
    self.attributes = a;
    }

- (instancetype)init
    {
    self = [super init];
    if (self)
        {
        _attributes = @{};
        }
    return self;
    }

+ (instancetype)functionWithName:(NSString*)name
                        function:(XTIRFunction*)function
                            type:(XTIRType*)type
    {
    XTIRSymbol* sym = [[self alloc] init];
    sym.kind = XTIRSymbolKindFunction;
    sym.name = name;
    sym.function = function;
    sym.functionType = type;
    return sym;
    }

+ (instancetype)dataGlobalWithName:(NSString*)name
                              type:(XTIRType*)type
                          volatile:(BOOL)volatileAccess
                           escapes:(BOOL)escapes
                         taskLocal:(BOOL)taskLocal
    {
    XTIRSymbol* sym = [[self alloc] init];
    sym.kind = XTIRSymbolKindDataGlobal;
    sym.name = name;
    sym.globalType = type;
    sym.volatileAccess = volatileAccess;
    sym.escapes = escapes;
    sym.taskLocal = taskLocal;
    return sym;
    }

+ (instancetype)runtimeHelperWithName:(NSString*)name
                           clobberSet:(XTIRClobberSet*)clobberSet
                             mayAlloc:(BOOL)mayAlloc
                             mayThrow:(BOOL)mayThrow
    {
    XTIRSymbol* sym = [[self alloc] init];
    sym.kind = XTIRSymbolKindRuntimeHelper;
    sym.name = name;
    sym.clobberSet = clobberSet;
    sym.mayAlloc = mayAlloc;
    sym.mayThrow = mayThrow;
    return sym;
    }

+ (instancetype)zpEquateWithName:(NSString*)name address:(uint16_t)address
    {
    XTIRSymbol* sym = [[self alloc] init];
    sym.kind = XTIRSymbolKindZpEquate;
    sym.name = name;
    sym.address = address;
    return sym;
    }

+ (instancetype)stringLitWithName:(NSString*)name bytes:(NSData*)bytes
    {
    XTIRSymbol* sym = [[self alloc] init];
    sym.kind = XTIRSymbolKindStringLit;
    sym.name = name;
    sym.stringBytes = bytes;
    return sym;
    }

+ (instancetype)vTableWithName:(NSString*)name layout:(nullable XTIRLayout*)layout
    {
    XTIRSymbol* sym = [[self alloc] init];
    sym.kind = XTIRSymbolKindVTable;
    sym.name = name;
    sym.vtableLayout = layout;
    return sym;
    }

@end
