// XTIRType.h — xtc new-IR type system (IR-SPEC §3)
#import <Foundation/Foundation.h>
#import "XTIRSupport.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIRLayout;

typedef NS_ENUM(uint8_t, XTIRTypeKind) {
    XTIRTypeKindVoid,
    XTIRTypeKindI8,
    XTIRTypeKindU8,
    XTIRTypeKindI16,
    XTIRTypeKindU16,
    XTIRTypeKindI32,
    XTIRTypeKindU32,
    XTIRTypeKindF32,
    XTIRTypeKindF64,
    XTIRTypeKindBool,
    XTIRTypeKindPtr, // Ptr(pointee: TypeRef, window: WindowId)
    XTIRTypeKindAgg, // Agg(layout: LayoutId)
    XTIRTypeKindMemory,
    XTIRTypeKindVec, // 128-bit SIMD vector of `pointeeType` lanes
    // Appended rather than inserted: renumbering XTTypeKind mid-enum broke
    // eight tests, and the same hazard applies here.
    XTIRTypeKindI64,
    XTIRTypeKindU64,
    // (internal to the arm64 vectorizer; not
    // round-tripped through the IR text)
};

/// Byte width for fixed-width types; 0 for Ptr, Agg, Void, Memory.
uint32_t XTIRTypeKindByteWidth(XTIRTypeKind kind);
BOOL XTIRTypeKindIsInteger(XTIRTypeKind kind);
BOOL XTIRTypeKindIsSigned(XTIRTypeKind kind);
BOOL XTIRTypeKindIsFloating(XTIRTypeKind kind);

@interface XTIRType : NSObject <NSCopying>

@property(nonatomic, readonly) XTIRTypeKind kind;

/// For Ptr: the pointee type (may be opaque/nullable).
@property(nonatomic, readonly, nullable) XTIRType* pointeeType;
/// For Ptr: the memory window.
@property(nonatomic, readonly) XTIRWindowId windowId;

/// For Agg: the layout describing fields.
@property(nonatomic, readonly, nullable) XTIRLayout* layout;

/// Byte width for fixed-width types.  Returns 0 for Ptr, Agg, Void, Memory.
@property(nonatomic, readonly) uint32_t byteWidth;

- (instancetype)initWithKind:(XTIRTypeKind)kind NS_DESIGNATED_INITIALIZER;

/// Create a Ptr(T, window).
- (instancetype)initWithPtrToType:(XTIRType*)pointee window:(XTIRWindowId)window;

/// Create an Agg(layout).
- (instancetype)initWithAggLayout:(XTIRLayout*)layout;

// Convenience singletons for fixed types.
+ (instancetype)voidType;
+ (instancetype)i8Type;
+ (instancetype)u8Type;
+ (instancetype)i16Type;
+ (instancetype)u16Type;
+ (instancetype)i32Type;
+ (instancetype)u32Type;
+ (instancetype)i64Type;
+ (instancetype)u64Type;
+ (instancetype)f32Type;
+ (instancetype)f64Type;
+ (instancetype)boolType;
+ (instancetype)memoryType;
+ (instancetype)ptrToType:(XTIRType*)pointee window:(XTIRWindowId)window;
+ (instancetype)aggWithLayout:(XTIRLayout*)layout;

/// A 128-bit SIMD vector whose lanes are `lane` (stored in pointeeType).
+ (instancetype)vecWithLane:(XTIRType*)lane;

@end

NS_ASSUME_NONNULL_END
