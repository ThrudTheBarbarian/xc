// XTIRInsn.h — single IR instruction (IR-SPEC §6)
#import <Foundation/Foundation.h>
#import "XTIROpcode.h"
#import "XTIRSupport.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIRValue;
@class XTIROperand;
@class XTIRCallConv;

@interface XTIRInsn : NSObject

/// The opcode (XTIROpcode enum).
@property(nonatomic, readonly) XTIROpcode opcode;

/// The value this instruction defines, or nil for instructions
/// that produce no result (Store, Branch, Return, etc.).
@property(nonatomic, readonly, nullable) XTIRValue* result;

/// The new memory token this instruction produces, or nil for ops
/// that don't touch memory. Ops with both a language-level result
/// and a memory result (Load, Call, AggLoad, VTblDispatch, etc.)
/// expose them as `result` and `memoryResult` respectively. Ops with
/// only a memory result (Store, MemCopy, Retain/Release, ...) have
/// `result == nil` and `memoryResult != nil`.
@property(nonatomic, strong, nullable) XTIRValue* memoryResult;

/// Operands — typed XTIROperand objects.
@property(nonatomic, readonly) NSArray<XTIROperand*>* operands;

/// Optional debug location.
@property(nonatomic, readonly, nullable) XTIRDbgLoc* dbgLoc;

/// Calling convention (only meaningful for call opcodes).
@property(nonatomic, readonly, nullable) XTIRCallConv* callConv;

/// ICmp/FCmp predicate (only for ICmp/FCmp opcodes).
@property(nonatomic, readonly) uint8_t predicate;

- (instancetype)initWithOpcode:(XTIROpcode)opcode
                        result:(nullable XTIRValue*)result
                      operands:(NSArray<XTIROperand*>*)operands
                        dbgLoc:(nullable XTIRDbgLoc*)dbgLoc NS_DESIGNATED_INITIALIZER;

/// Convenience: instruction with call convention.
- (instancetype)initWithOpcode:(XTIROpcode)opcode
                        result:(nullable XTIRValue*)result
                      operands:(NSArray<XTIROperand*>*)operands
                      callConv:(nullable XTIRCallConv*)callConv
                        dbgLoc:(nullable XTIRDbgLoc*)dbgLoc;

/// Convenience: instruction with predicate (ICmp/FCmp).
- (instancetype)initWithOpcode:(XTIROpcode)opcode
                        result:(nullable XTIRValue*)result
                      operands:(NSArray<XTIROperand*>*)operands
                     predicate:(uint8_t)predicate
                        dbgLoc:(nullable XTIRDbgLoc*)dbgLoc;

/// Is this instruction a terminator?
@property(nonatomic, readonly, getter=isTerminator) BOOL terminator;

/// Replace the operand array in place, preserving the instruction's
/// identity (opcode/result/memoryResult/callConv/predicate). Used by
/// opt passes that rewrite operand value-ids without rebuilding the
/// instruction object, so captured references stay valid (IR-SPEC §6).
- (void)replaceOperands:(NSArray<XTIROperand*>*)operands;

@end

NS_ASSUME_NONNULL_END
