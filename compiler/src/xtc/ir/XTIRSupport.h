// XTIRSupport.h — shared IR enumerations and lightweight value types
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Identifiers

/// Dense, function-local value identifier (IR-SPEC §4).
typedef uint32_t XTIRValueId;

/// Index into the module's symbol table.
typedef NSUInteger XTIRSymbolId;

/// Index into the module's constant pool.
typedef NSUInteger XTIRConstantId;

/// Index into the module's layout table.
typedef NSUInteger XTIRLayoutId;

#pragma mark - Window identifiers (IR-SPEC §3)

typedef NS_ENUM(uint8_t, XTIRWindowId) {
    XTIRWindowUnbanked, // plain load/store on every target
    XTIRWindowXtCode,   // $82-selected $6000-$9FFF
    XTIRWindowXtData,   // $83/$84-selected $A000-$CFFF
    XTIRWindowXlFlat,   // xl/xe unified, banking erased
};

#pragma mark - Calling convention (IR-SPEC §8)

typedef NS_ENUM(uint8_t, XTIRCallConvKind) {
    XTIRCallConvStandard,
    XTIRCallConvCloaked,
    XTIRCallConvBanked,
    XTIRCallConvInline,
    XTIRCallConvRuntimeHelper,
};

@interface XTIRCallConv : NSObject <NSCopying>
@property(nonatomic, readonly) XTIRCallConvKind kind;
@property(nonatomic, readonly) BOOL hwStack;
@property(nonatomic, readonly) BOOL naked;

- (instancetype)initWithKind:(XTIRCallConvKind)kind
                     hwStack:(BOOL)hwStack
                       naked:(BOOL)naked;

+ (instancetype)standard;
+ (instancetype)cloaked;
+ (instancetype)banked;
+ (instancetype)inlineConv;
+ (instancetype)runtimeHelper;
@end

#pragma mark - Comparison predicates (IR-SPEC §6.5)

typedef NS_ENUM(uint8_t, XTIRICmpPredicate) {
    XTIRICmpEQ,
    XTIRICmpNE,
    XTIRICmpSLT,
    XTIRICmpSGT,
    XTIRICmpSLE,
    XTIRICmpSGE,
    XTIRICmpULT,
    XTIRICmpUGT,
    XTIRICmpULE,
    XTIRICmpUGE,
};

typedef NS_ENUM(uint8_t, XTIRFCmpPredicate) {
    XTIRFCmpOEQ,
    XTIRFCmpONE,
    XTIRFCmpOLT,
    XTIRFCmpOGT,
    XTIRFCmpOLE,
    XTIRFCmpOGE,
    // Unordered variants omitted initially; add as needed.
};

#pragma mark - Debug location

@interface XTIRDbgLoc : NSObject
@property(nonatomic, readonly) uint32_t fileId;
@property(nonatomic, readonly) uint32_t line;
@property(nonatomic, readonly) uint32_t column;

- (instancetype)initWithFileId:(uint32_t)fileId
                          line:(uint32_t)line
                        column:(uint32_t)column;
@end

NS_ASSUME_NONNULL_END
