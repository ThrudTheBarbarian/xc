// XTIROptSimplify.h — integer arithmetic of constants folded, identities dropped
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// Integer arithmetic of constants folded, and the identities dropped: x+0,
// 0+x, x-0, x*1, 1*x, x|0, 0|x, x^0, 0^x, x&~0, ~0&x and shifts by 0 are x;
// x*0, 0*x, x&0, 0&x are 0. Folding is for the 8- to 32-bit types, the result
// wrapped to its width (unsigned in [0, 2^w), signed sign-extended); the
// identities hold at every width. A constant operand is an immediate, a Const,
// or a ZExt/SExt/Trunc of one (from 8 to 32 bits). Floats are untouched. The
// users of a dropped value read its operand (a use-rewrite); what is left dead
// the dead-code pass takes. Then each tree of one associative integer op (Add,
// Xor, And, Or) in a block is rebuilt shallowest-first, when that makes it
// shallower: md5's `((a + f) + m) + k` waits on f three times and becomes
// `f + (a + (m + k))`, whose m + k LICM hoists. A phi's value counts as
// deepest, so the value a loop carries is added last. -O2+, straight after
// mem2reg. As the port's simplify (selfhost/opt/Opt.xc).
@interface XTIROptSimplify : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
