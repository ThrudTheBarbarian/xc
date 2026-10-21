#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// bounds-elide: a checked build's subscript checks that cannot fail come out.
// A check `_xt_check_bounds_n(p, i, count, site)` in a block whose only way in
// is the true edge of `ICmp ULT i, B`, with B a constant no greater than
// count, is removed: on that edge i < B <= count. Mirrors the self-hosted
// Opt.boundsElide.
@interface XTIROptBoundsElide : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
