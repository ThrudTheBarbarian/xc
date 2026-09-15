#import "XTType.h"
#import "XTPointerType.h"

@interface XTType ()
@property(nonatomic, readwrite) XTTypeKind kind;
@property(nonatomic, readwrite) NSString* displayName;
@end

@implementation XTType

- (void)overrideDisplayName:(NSString*)name
    {
    _displayName = [name copy];
    }

/****************************************************************************\
|* Designated initialiser for type objects.
|* @param kind  The type-kind enum value.
|* @param name  The human-readable display name for diagnostics.
|* @return A new type object.
\****************************************************************************/
- (instancetype)initWithKind:(XTTypeKind)kind displayName:(NSString*)name
    {
    self = [super init];
    if (self)
        {
        _kind = kind;
        _displayName = [name copy];
        }
    return self;
    }

/****************************************************************************\
|* Return self since types are immutable singletons / value objects.
|* @param zone  Ignored.
|* @return self.
\****************************************************************************/
- (id)copyWithZone:(nullable NSZone*)zone
    {
    return self; // types are immutable singletons / value objects
    }

+ (instancetype)i8Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindI8 displayName:@"i8"];
    });
    return t;
    }
+ (instancetype)u8Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindU8 displayName:@"u8"];
    });
    return t;
    }
+ (instancetype)i16Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindI16 displayName:@"i16"];
    });
    return t;
    }
+ (instancetype)u16Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindU16 displayName:@"u16"];
    });
    return t;
    }
+ (instancetype)i32Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindI32 displayName:@"i32"];
    });
    return t;
    }
+ (instancetype)u32Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindU32 displayName:@"u32"];
    });
    return t;
    }
+ (instancetype)i64Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindI64 displayName:@"i64"];
    });
    return t;
    }
+ (instancetype)u64Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindU64 displayName:@"u64"];
    });
    return t;
    }
+ (instancetype)boolType
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindBool displayName:@"bool"];
    });
    return t;
    }
+ (instancetype)floatType
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindFloat displayName:@"float"];
    });
    return t;
    }
+ (instancetype)doubleType
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindDouble displayName:@"double"];
    });
    return t;
    }
+ (instancetype)voidType
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindVoid displayName:@"void"];
    });
    return t;
    }
static NSUInteger sFloatWidth = 5; // xtc's own format unless a target says otherwise
static BOOL sFloatIsIEEE = NO;

+ (NSUInteger)floatWidth
    {
    return sFloatWidth;
    }
+ (void)setFloatWidth:(NSUInteger)w
    {
    NSAssert(w == 4 || w == 5,
             @"floatWidth must be 4 or 5, got %lu",
             (unsigned long)w);
    sFloatWidth = w;
    }
+ (BOOL)floatIsIEEE
    {
    return sFloatIsIEEE;
    }
+ (void)setFloatIsIEEE:(BOOL)b
    {
    sFloatIsIEEE = b;
    }

+ (instancetype)autoType
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindAuto displayName:@"auto"];
    });
    return t;
    }
+ (instancetype)pointerType
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindPointer displayName:@"pointer"];
    });
    return t;
    }

/****************************************************************************\
|* Width of this type in bytes. Returns 0 for void/auto.
|* @return The byte width of the type.
\****************************************************************************/
- (NSUInteger)byteWidth
    {
    switch (_kind)
        {
    case XTTypeKindI8:
    case XTTypeKindU8:
    case XTTypeKindBool:
        return 1;
    case XTTypeKindI16:
    case XTTypeKindU16:
        return 2;
    case XTTypeKindPointer:
        return [XTPointerType heapPointerWidth];
    case XTTypeKindI32:
    case XTTypeKindU32:
        return 4;
    case XTTypeKindI64:
    case XTTypeKindU64:
        return 8;
    case XTTypeKindFloat:
        return [XTType floatWidth];
    case XTTypeKindDouble:
        return 8;
    default:
        return 0;
        }
    }

/****************************************************************************\
|* Returns YES for signed integer types (i8, i16, i32).
\****************************************************************************/
- (BOOL)isSigned
    {
    return (_kind == XTTypeKindI8 || _kind == XTTypeKindI16 ||
            _kind == XTTypeKindI32 || _kind == XTTypeKindI64);
    }

/****************************************************************************\
|* Returns YES for any integer-like type (i8/u8/i16/u16/i32/u32/bool/enum).
\****************************************************************************/
- (BOOL)isInteger
    {
    return (_kind == XTTypeKindI8 || _kind == XTTypeKindU8 ||
            _kind == XTTypeKindI16 || _kind == XTTypeKindU16 ||
            _kind == XTTypeKindI32 || _kind == XTTypeKindU32 ||
            _kind == XTTypeKindI64 || _kind == XTTypeKindU64 ||
            _kind == XTTypeKindBool || _kind == XTTypeKindEnum);
    }

/****************************************************************************\
|* Returns YES for the 5-byte float or 8-byte double type.
\****************************************************************************/
- (BOOL)isFloating
    {
    return _kind == XTTypeKindFloat || _kind == XTTypeKindDouble;
    }

/****************************************************************************\
|* Returns YES for pointer or array types (both are 2-byte addresses).
\****************************************************************************/
- (BOOL)isPointerLike
    {
    return (_kind == XTTypeKindPointer || _kind == XTTypeKindArray);
    }

/****************************************************************************\
|* Returns YES for the void type.
\****************************************************************************/
- (BOOL)isVoid
    {
    return _kind == XTTypeKindVoid;
    }

/****************************************************************************\
|* Returns YES for the auto placeholder type (pending inference).
\****************************************************************************/
- (BOOL)isAuto
    {
    return _kind == XTTypeKindAuto;
    }

/****************************************************************************\
|* Returns YES if this type can be implicitly converted to `other` without
|* data loss. Integer-to-integer and float-to/from-integer are allowed.
|* @param other  The target type to check compatibility with.
|* @return YES if implicit conversion is allowed.
\****************************************************************************/
- (BOOL)isCompatibleWithType:(XTType*)other
    {
    if (self == other)
        return YES;
    if (self.kind == other.kind)
        return YES;
    if (self.isInteger && other.isInteger)
        return YES;
    if (self.isFloating && other.isFloating)
        return YES;
    if (self.isFloating && other.isInteger)
        return YES;
    if (self.isInteger && other.isFloating)
        return YES;
    return NO;
    }

/****************************************************************************\
|* Returns the wider of the two types for binary-op type promotion. If either
|* is float, the result is float. Otherwise picks the wider integer, preferring
|* signed if either operand is signed.
|* @param a  The first operand type.
|* @param b  The second operand type.
|* @return The promoted type.
\****************************************************************************/
+ (XTType*)widenType:(XTType*)a with:(XTType*)b
    {
    if (a.kind == XTTypeKindDouble || b.kind == XTTypeKindDouble)
        return [XTType doubleType];
    if (a.isFloating || b.isFloating)
        return [XTType floatType];
    // Pointer arithmetic (`p + int` / `int + p`) keeps the POINTER type — never
    // collapse a pointer to a scalar by byte width. That collapse lost the
    // pointee, so `@(p ± N)` saw a non-pointer operand and defaulted its deref
    // to u8 (arch-dependently — the pointer's byte width is arch-specific): it
    // broke the value width AND, once the load was widened, produced an IR `Or`
    // whose result type disagreed with its operands (verifier reject on arm64).
    if (a.kind == XTTypeKindPointer && b.isInteger)
        return a;
    if (b.kind == XTTypeKindPointer && a.isInteger)
        return b;
    // Use byte width to decide, preferring signed if either is signed
    if (a.byteWidth >= b.byteWidth)
        {
        if (a.isSigned || b.isSigned)
            {
            // Return signed version of widest
            switch (MAX(a.byteWidth, b.byteWidth))
                {
            case 1:
                return [XTType i8Type];
            case 2:
                return [XTType i16Type];
            case 4:
                return [XTType i32Type];
            case 8:
                return [XTType i64Type];
            default:
                return a;
                }
            }
        return a;
        }
    else
        {
        if (b.isSigned || a.isSigned)
            {
            switch (MAX(a.byteWidth, b.byteWidth))
                {
            case 1:
                return [XTType i8Type];
            case 2:
                return [XTType i16Type];
            case 4:
                return [XTType i32Type];
            case 8:
                return [XTType i64Type];
            default:
                return b;
                }
            }
        return b;
        }
    }

/****************************************************************************\
|* Return the display name of this type for diagnostic output.
|* @return The type's display name string.
\****************************************************************************/
- (NSString*)description
    {
    return _displayName;
    }

@end
