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
// A loop the vectoriser leaves rotated — one block that branches back to itself
// — of several independent vector chains (v = v*k + c) and a counter from a
// constant to a constant bound by one, unrolled twice when the trip is even:
// the second copy reads the first's results and only its test drives the back
// edge. The block is then ordered chain by chain, so each fmla writes a
// register other than its multiplicand (#8: orr + fmla a step, not orr + fmla +
// orr). Profile-gated (unrollsChainLoops); arm64. As the port.
@interface XTIROptChainUnroll : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

@interface XTIROptLoopUnrollVarTrip : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
// Par kernels only: unroll a loop only when its constant trip is a whole
// number of groups, so no copy needs a guard. A GPU pays for the guards more
// than for the back edge they save (nbody's inner loop on the Pi 5's V3D:
// 110.7 ms rolled, 32.5 ms in exact groups, 270.8 ms guarded; issue #7).
@property(nonatomic) BOOL exactOnly;
@end

NS_ASSUME_NONNULL_END
