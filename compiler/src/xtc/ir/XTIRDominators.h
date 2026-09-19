// XTIRDominators.h — immediate dominators over a function's CFG
#import <Foundation/Foundation.h>

@class XTIRFunction, XTIRBlock;

NS_ASSUME_NONNULL_BEGIN

/// Immediate dominators, by the Cooper/Harvey/Kennedy iterative algorithm.
///
/// Built from the entry block outwards, so UNREACHABLE blocks are simply absent
/// — which matters more than it sounds. A pass that reasons "this block has one
/// predecessor, so that predecessor dominates it" is wrong when the predecessor
/// cannot itself be reached: the values it computes never exist at run time, and
/// forwarding them produces a program that reads registers nothing ever wrote.
@interface XTIRDominators : NSObject

/// Computes dominators for `fn`. Returns nil when the function has no entry.
+ (nullable instancetype)forFunction:(XTIRFunction*)fn;

/// The immediate dominator of `b`, or nil for the entry block and for any
/// block not reachable from it.
- (nullable XTIRBlock*)idomOf:(XTIRBlock*)b;

/// YES when `a` dominates `b` — every path from entry to `b` passes through
/// `a`. A block dominates itself. NO if either is unreachable.
- (BOOL)block:(XTIRBlock*)a dominates:(XTIRBlock*)b;

/// YES when the block is reachable from the entry.
- (BOOL)isReachable:(XTIRBlock*)b;

/// The reachable blocks in reverse postorder — every block appears after its
/// immediate dominator, which is the order a forward dataflow pass wants.
- (NSArray<XTIRBlock*>*)reversePostorder;

/// The reachable predecessors of `b`.
- (NSArray<XTIRBlock*>*)predecessorsOf:(XTIRBlock*)b;

@end

NS_ASSUME_NONNULL_END
