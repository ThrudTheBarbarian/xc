// XTIRBlock.h — basic block (IR-SPEC §2)
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class XTIRInsn;

/// A basic block: phi nodes, regular instructions, and exactly one
/// terminator (the last instruction).  Appending a regular instruction
/// after a terminator is an assertion failure.
@interface XTIRBlock : NSObject

/// Phi nodes at the start of the block.
@property(nonatomic, readonly) NSMutableArray<XTIRInsn*>* phiNodes;

/// Regular (non-terminator) instructions, after phis.
@property(nonatomic, readonly) NSMutableArray<XTIRInsn*>* instructions;

/// The single terminator instruction, or nil if not yet set.
@property(nonatomic, readonly, nullable) XTIRInsn* terminator;

/// Optional display name for debug output.
@property(nonatomic, copy, nullable) NSString* name;

/// Set when an instruction was appended to the block AFTER its
/// terminator was already set. The append goes directly into the
/// `instructions` array (bypassing `appendInstruction:`'s assertion)
/// so the verifier can detect §12.3 violations.
@property(nonatomic) BOOL hasInstructionAfterTerminator;

// Unreachable BY CONSTRUCTION: the exit of a `for (;;)` that nothing leaves by
// `break`. Code written after such a loop lands here and is dead, and the
// verifier accepts it and everything reachable only from it (bug 602).
// In-memory only, never printed, so the IR text is unchanged.
@property(nonatomic) BOOL deadByConstruction;

/// Append a regular instruction.  Asserts that no terminator has been set.
- (void)appendInstruction:(XTIRInsn*)insn;

/// Set the terminator instruction.  Asserts that no terminator is already set.
- (void)setTerminator:(XTIRInsn*)terminator;

/// Reset the terminator slot back to nil. Used by the lowering's
/// abandon-function path, which needs to replace a partial-body
/// terminator (potentially referencing blocks that have since been
/// dropped) with a fresh Unreachable.
- (void)resetTerminator;

/// Total instruction count (phis + instructions + 1 if terminator present).
@property(nonatomic, readonly) NSUInteger insnCount;

@end

NS_ASSUME_NONNULL_END