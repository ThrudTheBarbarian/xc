#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// `p[i]` with p = `a + k` (ElementAddr a, k: the same element type) is checked
// as `a[k + i]`: the heap check reads the block header at p, and a pointer into
// the middle of an array has none there. Followed through a chain of such
// additions; the sum is a u64, so a negative step wraps back into range. Runs
// at every level. The port's Opt.boundsOrigin.
@interface XTIROptBoundsOrigin : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
