#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIROptTargetProfile;

// Canonicalise a library square-root call into the `FSqrt` IR op, so the
// instruction-selection decision (hardware `fsqrt`/`vsqrt` vs a runtime call)
// lives in the backend keyed off the OPERATION, not off a magic symbol name.
//
// `Math.sqrt(x)` inlines down to a `Call _xm_sqrt[f]`; this pass rewrites that
// call (single fp arg → fp result) to `FSqrt x`. Gated on the target profile's
// `lowersSqrtToHardware`, so only targets with a hardware sqrt (arm64, arm9)
// canonicalise; the rest keep the call (6502 never emits one; soft-float m68k
// still needs the runtime routine).
@interface XTIROptSqrtIntrinsic : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
