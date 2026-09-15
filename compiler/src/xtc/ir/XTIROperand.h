// XTIROperand.h — tagged-sum operand types (IR-SPEC §4)
#import <Foundation/Foundation.h>
#import "XTIRSupport.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIRType;
@class XTIRBlock;

typedef NS_ENUM(uint8_t, XTIROperandKind) {
    XTIROperandKindUse,      // SSA value reference
    XTIROperandKindImmI,     // typed integer immediate
    XTIROperandKindImmF,     // typed float/double immediate (raw IEEE double)
    XTIROperandKindSym,      // symbol-table reference
    XTIROperandKindBlock,    // basic-block reference
    XTIROperandKindConstAgg, // constant aggregate
};

/// Tagged operand.  Each kind has a specific set of valid accessors:
///
///   Use     → valueId
///   ImmI    → type, intValue
///   ImmF    → type, floatRawBytes
///   Sym     → symbolId
///   Block   → blockRef
///   ConstAgg → constantId
@interface XTIROperand : NSObject

@property(nonatomic, readonly) XTIROperandKind kind;

// -- valid for Use --
@property(nonatomic, readonly) XTIRValueId valueId;

// -- valid for ImmI, ImmF --
@property(nonatomic, readonly, nullable) XTIRType* type;

// -- valid for ImmI --
@property(nonatomic, readonly) int64_t intValue;

// -- valid for ImmF — raw IEEE 754 double bits --
@property(nonatomic, readonly) uint64_t floatRawBytes;

// -- valid for Sym --
@property(nonatomic, readonly) XTIRSymbolId symbolId;

// -- valid for Block --
@property(nonatomic, readonly, weak) XTIRBlock* blockRef;

// -- valid for ConstAgg --
@property(nonatomic, readonly) XTIRConstantId constantId;

+ (instancetype)useWithValueId:(XTIRValueId)valueId;
+ (instancetype)immIWithType:(XTIRType*)type value:(int64_t)value;
+ (instancetype)immFWithType:(XTIRType*)type rawBytes:(uint64_t)rawBytes;
+ (instancetype)symWithSymbolId:(XTIRSymbolId)symbolId;
+ (instancetype)blockWithRef:(XTIRBlock*)blockRef;
+ (instancetype)constAggWithConstantId:(XTIRConstantId)constantId;

@end

NS_ASSUME_NONNULL_END
