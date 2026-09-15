#import "XTLabelGenerator.h"
#import "XTPointerType.h"
#import "XTArrayType.h"
#import "XTStructType.h"
#import "XTEnumType.h"

@interface XTLabelGenerator ()
@property(nonatomic) NSUInteger labelCounter;
@property(nonatomic) NSUInteger stringCounter;
@end

@implementation XTLabelGenerator

/****************************************************************************\
|* Initialise a label generator with counters starting at zero.
|* @return  A fresh label generator instance.
\****************************************************************************/
- (instancetype)init
    {
    self = [super init];
    if (self)
        {
        _labelCounter = 0;
        _stringCounter = 0;
        }
    return self;
    }

/****************************************************************************\
|* Returns a fresh unique label, e.g. "_L001"
|* @return  A unique label string, prefixed with modulePrefix if set.
\****************************************************************************/
- (NSString*)nextLabel
    {
    if (_modulePrefix)
        {
        return [NSString stringWithFormat:@"_%@L%04lu", _modulePrefix, (unsigned long)_labelCounter++];
        }
    return [NSString stringWithFormat:@"_L%04lu", (unsigned long)_labelCounter++];
    }

/****************************************************************************\
|* Returns a label derived from a function name, e.g. "_fn_main"
|* @param name  The function name to derive the label from.
|* @return  A label string in the form "_fn_<name>".
\****************************************************************************/
- (NSString*)labelForFunction:(NSString*)name
    {
    return [NSString stringWithFormat:@"_fn_%@", name];
    }

/****************************************************************************\
|* Suffix string for a single type (e.g. `u8`, `pu8`, `SPoint`,
|* `eDirection`). Exposed mainly for tests/diagnostics.
|* @param t  The type to produce a mangling suffix for.
|* @return  A short string encoding the type kind, or "v" for nil/void.
\****************************************************************************/
+ (NSString*)manglingSuffixForType:(XTType*)t
    {
    if (!t)
        return @"v";
    switch (t.kind)
        {
    case XTTypeKindVoid:
        return @"v";
    case XTTypeKindBool:
        return @"b";
    case XTTypeKindI8:
        return @"i8";
    case XTTypeKindU8:
        return @"u8";
    case XTTypeKindI16:
        return @"i16";
    case XTTypeKindU16:
        return @"u16";
    case XTTypeKindI32:
        return @"i32";
    case XTTypeKindU32:
        return @"u32";
    case XTTypeKindI64:
        return @"i64";
    case XTTypeKindU64:
        return @"u64";
    case XTTypeKindFloat:
        return @"f";
    case XTTypeKindDouble:
        return @"double";
    case XTTypeKindPointer:
        {
        // The bare `pointer` keyword is a plain XTType with kind Pointer and
        // no pointee — only a typed `T@` is an XTPointerType. Guard the cast:
        // an unguarded `.pointeeType` on a bare pointer sent an unrecognized
        // selector and crashed the compiler (XTC-BUGS #17, void redeclaration).
        if (![t isKindOfClass:[XTPointerType class]])
            return @"p";
        XTType* pointee = ((XTPointerType*)t).pointeeType;
        // Treat `u8@` as string for aesthetic reasons (xtc uses
        // `string` as an alias for `u8@`).
        if (pointee && pointee.kind == XTTypeKindU8)
            return @"s";
        return [NSString stringWithFormat:@"p%@", [self manglingSuffixForType:pointee]];
        }
    case XTTypeKindArray:
        {
        XTType* el = ((XTArrayType*)t).elementType;
        return [NSString stringWithFormat:@"a%@", [self manglingSuffixForType:el]];
        }
    case XTTypeKindStruct:
        {
        NSString* sn = ((XTStructType*)t).structName;
        return [NSString stringWithFormat:@"S%@", sn ?: @"anon"];
        }
    case XTTypeKindEnum:
        {
        NSString* en = ((XTEnumType*)t).enumName;
        return [NSString stringWithFormat:@"e%@", en ?: @"anon"];
        }
    case XTTypeKindClass:
        {
        // Class by value is unusual; use the display name.
        return [NSString stringWithFormat:@"C%@", t.displayName ?: @"anon"];
        }
    default:
        return t.displayName ?: @"x";
        }
    }

/****************************************************************************\
|* Build the overload suffix for a function name given its parameter
|* types, producing e.g. `print__u32` or `log__s_u8`. For empty
|* parameter lists returns `<name>__v`. Used by sema when stamping
|* mangled names onto decl nodes that participate in an overload set.
|* @param base   The unmangled function name.
|* @param types  The parameter types in declaration order.
|* @return  The mangled name with a double-underscore separator.
\****************************************************************************/
+ (NSString*)mangleName:(NSString*)base paramTypes:(NSArray<XTType*>*)types
    {
    return [self mangleName:base paramTypes:types returnType:nil];
    }

+ (NSString*)mangleName:(NSString*)base
             paramTypes:(NSArray<XTType*>*)types
             returnType:(XTType*)returnType
    {
    if (types.count == 0)
        {
        // Zero-arg methods: include the return type as a disambiguator
        // when one is provided. Lets Math.PI() exist as both float and
        // double overloads — they share the __v parameter suffix but
        // mangle to `PI__v_f` and `PI__v_double` respectively.
        if (returnType)
            {
            return [NSString stringWithFormat:@"%@__v_%@",
                                              base, [self manglingSuffixForType:returnType]];
            }
        return [NSString stringWithFormat:@"%@__v", base];
        }
    NSMutableString* s = [NSMutableString stringWithString:base];
    [s appendString:@"__"];
    BOOL first = YES;
    for (XTType* t in types)
        {
        if (!first)
            [s appendString:@"_"];
        first = NO;
        [s appendString:[self manglingSuffixForType:t]];
        }
    return s;
    }

/****************************************************************************\
|* Returns a label for a string constant, e.g. "_str003"
|* @return  A unique string label, prefixed with modulePrefix if set.
\****************************************************************************/
- (NSString*)nextStringLabel
    {
    if (_modulePrefix)
        {
        return [NSString stringWithFormat:@"_%@str%04lu", _modulePrefix, (unsigned long)_stringCounter++];
        }
    return [NSString stringWithFormat:@"_str%04lu", (unsigned long)_stringCounter++];
    }

@end
