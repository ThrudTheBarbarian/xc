// XTIROptStaticInitGuard.h — redundant static-init-guard elimination.
//
// The lowering emits, before every static-method call, an init-on-first-use
// guard:  if (__sinit_X == 0) { __sinit_X = 1; X$init(); }  After any one
// such guard for class X has run, the flag is set on all later paths, so a
// second guard for the same class that is dominated by the first is a no-op
// — it can be folded to the straight-through edge, dropping the load/compare/
// branch and the dead init block. This is a pure dominator-based redundancy
// removal; it never reorders init relative to a use. -O2+, profile-gated
// (the fold leaves the dead guard's memory tokens dangling, harmless only
// where the backend treats them as advisory).
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIROptTargetProfile;

@interface XTIROptStaticInitGuard : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
