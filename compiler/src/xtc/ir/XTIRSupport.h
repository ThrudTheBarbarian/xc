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

/****************************************************************************\
|* The location lowering is at, under -g. An instruction made without an
|* explicit location takes this one, so each statement's code carries the
|* statement's line without every construction site passing it. Nil (the
|* default, and always without -g) leaves instructions without a location.
\****************************************************************************/
+ (nullable XTIRDbgLoc*)current;
+ (void)setCurrent:(nullable XTIRDbgLoc*)loc;

/****************************************************************************\
|* The source files locations refer to, by id: the IR text's dbgfile lines.
|* Reset at the start of each module's lowering (and of each parse).
\****************************************************************************/
+ (uint32_t)fileIdForPath:(NSString*)path;
+ (void)setPath:(NSString*)path forFileId:(uint32_t)fileId;
+ (NSArray<NSString*>*)files;
+ (void)resetFiles;
// A path as the debug information records it: absolute, with no . or ..
+ (NSString*)canonicalPath:(NSString*)path;
@end

NS_ASSUME_NONNULL_END
