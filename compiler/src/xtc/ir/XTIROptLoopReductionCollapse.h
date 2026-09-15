#import "XTIROptPass.h"

@class XTIROptTargetProfile;

NS_ASSUME_NONNULL_BEGIN

// Loop reduction-nest collapse. Recognises an outer counted loop (constant
// trip T) whose only loop-carried value besides its induction variable is an
// integer accumulator `acc += delta`, where `delta` is invariant across the
// outer loop — the shape clang produces when it hoists an invariant inner
// map/reduce loop out of an enclosing `rep` loop and multiplies the reduction
// by the trip count. xtc otherwise recomputes the whole inner loop every outer
// iteration.
//
// The `delta` may be produced by a nested inner reduction loop that reads only
// outer-invariant arrays; the collapse computes that inner loop's result once
// (in the outer preheader) and closes the outer loop to `acc += T·delta`.
//
// Soundness: the accumulate op is associative/commutative over 2's-complement
// integers (currently `+`, so `T·delta mod 2^w` == T repeated adds), and the
// outer loop body writes no memory that the outer loop re-reads across
// iterations (checked with a distinct-symbol read/write-set analysis; the pass
// bails the instant a base can't be resolved to a distinct top-level symbol).
// Profile-gated (collapsesInvariantReductions — arm64 only). -O2+.
@interface XTIROptLoopReductionCollapse : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
