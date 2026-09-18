// XTIROptJumpThread.h — resolve a CondBranch on a phi with a constant incoming
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

/// When a block does nothing but merge a boolean and branch on it, a
/// predecessor supplying a CONSTANT already knows where control goes. Rewiring
/// it to jump straight there removes its edge, and once the phi is down to one
/// incoming the boolean stops existing at all.
///
/// This is what a short-circuit `&&` leaves behind: the left-hand test's false
/// arm feeds the merge a literal 0, so it is really a branch to the loop exit
/// wearing a phi. sort_small's `j > 0 && a[j-1] > v` was materialising that 0,
/// storing it to a frame slot and loading it back on every iteration of an
/// O(n^2) loop — the merge cannot be if-converted, because the right-hand arm
/// loads a[j-1] and j may be 0.
@interface XTIROptJumpThread : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
