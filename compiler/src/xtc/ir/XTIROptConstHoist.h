#import "XTIROptPass.h"

@class XTIROptTargetProfile;

NS_ASSUME_NONNULL_BEGIN

// Float-constant deduplication / hoisting. Loop unrolling and inlining
// replicate the same float Const (e.g. ahl's 0.5 and 2^31) into every copy;
// each materialises via movz/movk + fmov since fp ops take no immediate. This
// pass collapses identical float Consts (by type + raw bits) to one definition
// hoisted to the entry block, which dominates all uses — so it is built once
// and the register allocator homes it in a callee-saved d-reg, read in place
// across the loop (matching clang). Bit-exact (same value, fewer instructions).
// Only groups that actually repeat are hoisted; singletons stay put. -O2+.
//
// When the target profile sets `hoistsGlobalAddr`, the same machinery also
// dedups repeated `AddrOf @sym` (loop-invariant global addresses) to the entry
// block — keyed by symbol + pointee type so the backend's base-typed
// element/field stride stays correct — so a global touched across several loops
// computes its base once and the allocator homes it.
@interface XTIROptConstHoist : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
