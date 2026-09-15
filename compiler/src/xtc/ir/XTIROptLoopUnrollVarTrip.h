#import "XTIROptPass.h"

@class XTIROptTargetProfile;

NS_ASSUME_NONNULL_BEGIN

// Partial unrolling of a *variable*-trip loop (unknown iteration count): a
// single-block-body loop `for(iv; iv<cmp>bound; iv+=step) body` is rewritten so
// the body runs N times in sequence per back-edge, each copy past the first
// guarded by a clone of the loop test that exits inline when the trip ends — no
// separate remainder loop. Sound by construction: the copies execute the
// original body / increment / compare in the original order, just regrouped, so
// the back-edge (and its branch/increment overhead) fires once per N bodies.
// Profile-gated (unrollsVariableTrip); arm64 only. -O2+.
@interface XTIROptLoopUnrollVarTrip : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
