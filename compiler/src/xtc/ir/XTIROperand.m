// XTIROperand.m
#import "XTIROperand.h"
#import "XTIRType.h"
#import "XTIRBlock.h"

@interface XTIROperand ()
@property(nonatomic, readwrite) XTIROperandKind kind;
@property(nonatomic, readwrite, nullable) XTIRType* type;
@property(nonatomic, readwrite) XTIRValueId valueId;
@property(nonatomic, readwrite) int64_t intValue;
@property(nonatomic, readwrite) uint64_t floatRawBytes;
@property(nonatomic, readwrite) XTIRSymbolId symbolId;
@property(nonatomic, readwrite, weak) XTIRBlock* blockRef;
@property(nonatomic, readwrite) XTIRConstantId constantId;
@end

@implementation XTIROperand

+ (instancetype)useWithValueId:(XTIRValueId)valueId
    {
    XTIROperand* op = [[self alloc] init];
    op.kind = XTIROperandKindUse;
    op.valueId = valueId;
    return op;
    }

+ (instancetype)immIWithType:(XTIRType*)type value:(int64_t)value
    {
    XTIROperand* op = [[self alloc] init];
    op.kind = XTIROperandKindImmI;
    op.type = type;
    op.intValue = value;
    return op;
    }

+ (instancetype)immFWithType:(XTIRType*)type rawBytes:(uint64_t)rawBytes
    {
    XTIROperand* op = [[self alloc] init];
    op.kind = XTIROperandKindImmF;
    op.type = type;
    op.floatRawBytes = rawBytes;
    return op;
    }

+ (instancetype)symWithSymbolId:(XTIRSymbolId)symbolId
    {
    XTIROperand* op = [[self alloc] init];
    op.kind = XTIROperandKindSym;
    op.symbolId = symbolId;
    return op;
    }

+ (instancetype)blockWithRef:(XTIRBlock*)blockRef
    {
    XTIROperand* op = [[self alloc] init];
    op.kind = XTIROperandKindBlock;
    op.blockRef = blockRef;
    return op;
    }

+ (instancetype)constAggWithConstantId:(XTIRConstantId)constantId
    {
    XTIROperand* op = [[self alloc] init];
    op.kind = XTIROperandKindConstAgg;
    op.constantId = constantId;
    return op;
    }

- (NSString*)description
    {
    switch (self.kind)
        {
    case XTIROperandKindUse:
        return [NSString stringWithFormat:@"%%%u", self.valueId];
    case XTIROperandKindImmI:
        return [NSString stringWithFormat:@"#%lld", self.intValue];
    case XTIROperandKindImmF:
        return [NSString stringWithFormat:@"#float(%016llx)", self.floatRawBytes];
    case XTIROperandKindSym:
        return [NSString stringWithFormat:@"@sym(%lu)", (unsigned long)self.symbolId];
    case XTIROperandKindBlock:
        return [NSString stringWithFormat:@"block(%p)", self.blockRef];
    case XTIROperandKindConstAgg:
        return [NSString stringWithFormat:@"@cpool(%lu)", (unsigned long)self.constantId];
        }
    }

@end
