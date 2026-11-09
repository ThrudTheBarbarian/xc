#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// A heap check on p[i] in a loop that cannot change p's block header reads the
// same header every time round. The header's verdict, as a bound, is computed
// once before the loop by Checked.xc's _xt_check_limit, and the loop calls the
// check only for an index at or past it: a check that would fail still runs,
// on the same iteration. The port's Opt.boundsHoist (OptBoundsElide.xc), which
// explains the rest.
@interface XTIROptBoundsHoist : NSObject <XTIROptPass>
@end

// A counted loop whose hoisted checks are on p[i] runs an unchecked copy of
// itself when its trip count is within every bound, the checked loop
// otherwise. The port's Opt.boundsVersion (OptBoundsElide.xc).
@interface XTIROptBoundsVersion : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
