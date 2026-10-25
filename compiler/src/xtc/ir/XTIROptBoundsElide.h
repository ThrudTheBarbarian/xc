#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// bounds-elide: a checked build's subscript checks that cannot fail come out.
// A check `_xt_check_bounds_n(p, i, count, site)` in a block whose only way in
// is the true edge of `ICmp ULT i, B`, with B a constant no greater than
// count, is removed: on that edge i < B <= count. Mirrors the self-hosted
// Opt.boundsElide.
@class XTIROptTargetProfile;

@interface XTIROptBoundsElide : NSObject <XTIROptPass>
// The target's, for the if-conversion a function gets again once checks
// came out of it (an `if` body with a check in it was a call, and stayed a
// branch). Nil: none.
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
