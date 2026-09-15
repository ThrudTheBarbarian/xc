// XTIRFunction.h — IR function container (IR-SPEC §2)
#import <Foundation/Foundation.h>
#import "XTIRSupport.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIRType;
@class XTIRBlock;
@class XTIRValue;
@class XTIRInsn;

/// A single pinned-local descriptor: a frame-resident slot the
/// function declares so that AddrOf-able semantics work (IR-SPEC §6.6,
/// §12.7). Pinned locals get an SSA value-id at function entry so
/// AddrOf operands can reference them uniformly with parameters.
@interface XTIRPinnedLocal : NSObject
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly) XTIRType* type;
@property(nonatomic, readonly) uint32_t byteOffset;
@property(nonatomic, readonly) XTIRValueId valueId;
/// YES when this local's address is dereferenced across calls, so it
/// must live at a stable per-invocation address rather than in a shared
/// scratch pool. Stack-allocated (value) class instances set this: the
/// instance is only ever reached through its self-pointer, and a backend
/// that placed it in a globally-shared scratch region (e.g. the 6502 ZP
/// pinned-local pool) would see it clobbered by any callee — including a
/// transitively-reached one — that reuses the same region. Backends that
/// already give every pinned local a stable frame slot can ignore it.
@property(nonatomic) BOOL escapesViaPointer;

- (instancetype)initWithName:(NSString*)name
                        type:(XTIRType*)type
                  byteOffset:(uint32_t)byteOffset
                     valueId:(XTIRValueId)valueId;
@end

/// Frame information for a function.
@interface XTIRFrameInfo : NSObject
/// Declared total pinned-local frame size, in bytes. The verifier's
/// invariant §12.11 requires this to equal the sum of pinned-local
/// byte widths.
@property(nonatomic) uint32_t pinnedLocalSize;
@property(nonatomic) uint32_t slotCount;
/// Pinned-local descriptors, in declaration order.
@property(nonatomic, copy) NSArray<XTIRPinnedLocal*>* pinnedLocals;
@end

@interface XTIRFunction : NSObject

/// Function name.
@property(nonatomic, readonly, copy) NSString* name;

/// Return type.
@property(nonatomic, readonly) XTIRType* returnType;

/// Parameter types (including the implicit memory token as the last param).
@property(nonatomic, readonly) NSArray<XTIRType*>* paramTypes;

/// Entry block.
@property(nonatomic, readonly) XTIRBlock* entryBlock;

/// All blocks (entry is first).
@property(nonatomic, readonly) NSMutableArray<XTIRBlock*>* blocks;

/// Frame info.
@property(nonatomic, readonly) XTIRFrameInfo* frameInfo;

/// Loop-header block names the source asked to have unrolled with `: unroll`.
///
/// The IR carries no per-loop metadata of any kind, and this is deliberately
/// the smallest thing that changes that: a set of NAMES, printed as one
/// conditional `unroll: [...]` line beside `frame:` and only when non-empty,
/// so no existing fixture's IR text moves. The alternative — a marker opcode —
/// would have touched the opcode enum, the printer, the parser, the verifier
/// and every back end in both compilers, to carry one bit.
///
/// It is a HINT, not an instruction: the unroll pass relaxes its trip and body
/// BUDGETS for a listed header and leaves every correctness gate (multi-carry
/// phis, vector phis, loop shape) exactly where it was.
@property(nonatomic, readonly) NSMutableSet<NSString*>* forcedUnrollHeaders;

/// All values defined in this function, keyed by valueId.
@property(nonatomic, readonly) NSMutableDictionary<NSNumber*, XTIRValue*>* values;

- (instancetype)initWithName:(NSString*)name
                  returnType:(XTIRType*)returnType
                  paramTypes:(NSArray<XTIRType*>*)paramTypes
                  entryBlock:(XTIRBlock*)entryBlock NS_DESIGNATED_INITIALIZER;

/// Allocate a monotonically increasing value id for this function.
- (XTIRValueId)allocateValueId;

/// Register a value (checks for duplicate id).
- (void)registerValue:(XTIRValue*)value;

/// Look up a value by id.
- (nullable XTIRValue*)valueForId:(XTIRValueId)valueId;

/// Next unallocated value id.
@property(nonatomic, readonly) XTIRValueId nextValueId;

/// Every value this function defines, in PRINT order: parameters, pinned
/// locals, then block by block — phi results, instruction results, the
/// terminator's — each memory result right after its value. This is the
/// order XTIRPrinter numbers them in (buildContextForFunction:), so it is
/// the numbering the self-hosted compiler reads. A back end that lays out
/// frame slots by value id is laying them out by CREATION order instead,
/// and the two part company the moment a pass moves an instruction: the
/// static-init hoist leaves a Load's id where it was while printing it
/// last, so the same value sat at [rbp-16] on one side and [rbp-56] on the
/// other (bug 090). Lay out in this order and the two agree by construction.
- (NSArray<XTIRValue*>*)valuesInPrintOrder;

@end

NS_ASSUME_NONNULL_END
