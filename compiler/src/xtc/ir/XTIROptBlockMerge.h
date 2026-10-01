// XTIROptBlockMerge.h — fold a block into its only predecessor
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

/// When a block A ends in an unconditional branch to B, and A is the only way
/// into B, the two are one straight run of code split in two. Folding B into A
/// removes the branch and, more usefully, the block boundary: an unrolled loop
/// body is four copies chained by plain branches, which loop rotation and the
/// back ends treat as four blocks; merged, it is the single-block body they
/// handle best.
@interface XTIROptBlockMerge : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
