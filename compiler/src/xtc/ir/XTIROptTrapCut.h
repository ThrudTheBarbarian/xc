#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// A check that fails calls a trap that never returns (_xt_check_trap,
// _xt_check_cast_trap). Ending its block there, with Unreachable, takes the
// trap's path out of the loop it sits in: the loop's body then holds no call,
// and the loads the check made of an array's header hoist (issue #28).
// Lowering carries a join on from one side's memory token rather than merging
// them, so a token the trap made may be named after the join: it is renamed
// to the token the trap call took. Runs after the checks are inlined. The
// port's Opt.trapCut.
@interface XTIROptTrapCut : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
