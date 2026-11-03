// XTIROptBlockMerge.h — fold a block into its only predecessor
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIRFunction;

/// When a block A ends in an unconditional branch to B, and A is the only way
/// into B, the two are one straight run of code split in two. Folding B into A
/// removes the branch and, more usefully, the block boundary: an unrolled loop
/// body is four copies chained by plain branches, which loop rotation and the
/// back ends treat as four blocks; merged, it is the single-block body they
/// handle best.
@interface XTIROptBlockMerge : NSObject <XTIROptPass>
- (void)pruneStaleIncomings:(XTIRFunction*)fn;
@end

// A CondBranch on a constant becomes a Branch, and the blocks no path from the
// entry reaches any more go, with their phi incomings; then again, for a
// branch on a phi those incomings left one value. `Par.kept(n)`, which
// par-check answers, is what makes these: the side of a lifted loop's site it
// does not take must not stay in the function. As the port's constBranches.
@interface XTIROptConstBranches : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
