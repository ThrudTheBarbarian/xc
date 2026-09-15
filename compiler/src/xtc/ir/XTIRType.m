// XTIRType.m
#import "XTIRType.h"
#import "XTIRLayout.h"

uint32_t XTIRTypeKindByteWidth(XTIRTypeKind kind)
    {
    switch (kind)
        {
    case XTIRTypeKindBool:
        return 1;
    case XTIRTypeKindI8:
    case XTIRTypeKindU8:
        return 1;
    case XTIRTypeKindI16:
    case XTIRTypeKindU16:
        return 2;
    case XTIRTypeKindI32:
    case XTIRTypeKindU32:
        return 4;
    case XTIRTypeKindI64:
    case XTIRTypeKindU64:
        return 8;
    case XTIRTypeKindF32:
        return 4;
    case XTIRTypeKindF64:
        return 8;
    default:
        return 0; // Ptr, Agg, Void, Memory
        }
    }

BOOL XTIRTypeKindIsInteger(XTIRTypeKind kind)
    {
    switch (kind)
        {
    case XTIRTypeKindI8:
    case XTIRTypeKindU8:
    case XTIRTypeKindI16:
    case XTIRTypeKindU16:
    case XTIRTypeKindI32:
    case XTIRTypeKindU32:
    case XTIRTypeKindI64:
    case XTIRTypeKindU64:
        return YES;
    default:
        return NO;
        }
    }

BOOL XTIRTypeKindIsSigned(XTIRTypeKind kind)
    {
    switch (kind)
        {
    case XTIRTypeKindI8:
    case XTIRTypeKindI16:
    case XTIRTypeKindI32:
    case XTIRTypeKindI64:
        return YES;
    default:
        return NO;
        }
    }

BOOL XTIRTypeKindIsFloating(XTIRTypeKind kind)
    {
    switch (kind)
        {
    case XTIRTypeKindF32:
    case XTIRTypeKindF64:
        return YES;
    default:
        return NO;
        }
    }

#pragma mark - XTIRType

@implementation XTIRType

- (instancetype)initWithKind:(XTIRTypeKind)kind
    {
    NSParameterAssert(kind != XTIRTypeKindPtr && kind != XTIRTypeKindAgg);
    self = [super init];
    if (self)
        {
        _kind = kind;
        _windowId = XTIRWindowUnbanked;
        }
    return self;
    }

- (instancetype)initWithPtrToType:(XTIRType*)pointee window:(XTIRWindowId)window
    {
    self = [super init];
    if (self)
        {
        _kind = XTIRTypeKindPtr;
        _pointeeType = pointee;
        _windowId = window;
        }
    return self;
    }

- (instancetype)initWithAggLayout:(XTIRLayout*)layout
    {
    self = [super init];
    if (self)
        {
        _kind = XTIRTypeKindAgg;
        _layout = layout;
        _windowId = XTIRWindowUnbanked;
        }
    return self;
    }

- (instancetype)initVecWithLane:(XTIRType*)lane
    {
    self = [super init];
    if (self)
        {
        _kind = XTIRTypeKindVec;
        _pointeeType = lane; // reuse pointeeType to carry the lane type
        _windowId = XTIRWindowUnbanked;
        }
    return self;
    }

- (uint32_t)byteWidth
    {
    if (self.kind == XTIRTypeKindAgg)
        {
        return self.layout ? self.layout.size : 0;
        }
    if (self.kind == XTIRTypeKindVec)
        return 16; // 128-bit
    return XTIRTypeKindByteWidth(self.kind);
    }

- (id)copyWithZone:(nullable NSZone*)zone
    {
    switch (self.kind)
        {
    case XTIRTypeKindPtr:
        return [[XTIRType alloc] initWithPtrToType:self.pointeeType window:self.windowId];
    case XTIRTypeKindAgg:
        return [[XTIRType alloc] initWithAggLayout:self.layout];
    case XTIRTypeKindVec:
        return [XTIRType vecWithLane:self.pointeeType];
    default:
        return [[XTIRType alloc] initWithKind:self.kind];
        }
    }

- (BOOL)isEqual:(nullable id)object
    {
    if (![object isKindOfClass:[XTIRType class]])
        return NO;
    XTIRType* other = (XTIRType*)object;
    if (self.kind != other.kind)
        return NO;
    if (self.kind == XTIRTypeKindPtr)
        {
        return (self.pointeeType == other.pointeeType || [self.pointeeType isEqual:other.pointeeType]) && self.windowId == other.windowId;
        }
    if (self.kind == XTIRTypeKindAgg)
        {
        return self.layout == other.layout || [self.layout isEqual:other.layout];
        }
    return YES;
    }

- (NSUInteger)hash
    {
    return (NSUInteger)self.kind;
    }

#pragma mark - Convenience singletons

+ (instancetype)voidType
    {
    return [(XTIRType*)[self alloc] initWithKind:XTIRTypeKindVoid];
    }
+ (instancetype)i8Type
    {
    return [(XTIRType*)[self alloc] initWithKind:XTIRTypeKindI8];
    }
+ (instancetype)u8Type
    {
    return [(XTIRType*)[self alloc] initWithKind:XTIRTypeKindU8];
    }
+ (instancetype)i16Type
    {
    return [(XTIRType*)[self alloc] initWithKind:XTIRTypeKindI16];
    }
+ (instancetype)u16Type
    {
    return [(XTIRType*)[self alloc] initWithKind:XTIRTypeKindU16];
    }
+ (instancetype)i32Type
    {
    return [(XTIRType*)[self alloc] initWithKind:XTIRTypeKindI32];
    }
+ (instancetype)u32Type
    {
    return [(XTIRType*)[self alloc] initWithKind:XTIRTypeKindU32];
    }
+ (instancetype)i64Type
    {
    return [(XTIRType*)[self alloc] initWithKind:XTIRTypeKindI64];
    }
+ (instancetype)u64Type
    {
    return [(XTIRType*)[self alloc] initWithKind:XTIRTypeKindU64];
    }
+ (instancetype)f32Type
    {
    return [(XTIRType*)[self alloc] initWithKind:XTIRTypeKindF32];
    }
+ (instancetype)f64Type
    {
    return [(XTIRType*)[self alloc] initWithKind:XTIRTypeKindF64];
    }
+ (instancetype)boolType
    {
    return [(XTIRType*)[self alloc] initWithKind:XTIRTypeKindBool];
    }
+ (instancetype)memoryType
    {
    return [(XTIRType*)[self alloc] initWithKind:XTIRTypeKindMemory];
    }

+ (instancetype)ptrToType:(XTIRType*)pointee window:(XTIRWindowId)window
    {
    return [[self alloc] initWithPtrToType:pointee window:window];
    }

+ (instancetype)aggWithLayout:(XTIRLayout*)layout
    {
    return [[self alloc] initWithAggLayout:layout];
    }

+ (instancetype)vecWithLane:(XTIRType*)lane
    {
    XTIRType* t = [super alloc];
    return [t initVecWithLane:lane];
    }

@end
