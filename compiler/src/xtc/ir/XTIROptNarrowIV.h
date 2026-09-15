#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIROptTargetProfile;

// Induction-variable width narrowing. A counted loop whose integer IV
//   iv = phi[(preheader, c0), (latch, iv + step)]     c0 >= 0, step > 0 const
//   guard: ICmp <pred> iv, BOUND                       BOUND >= 0 const
// where every DIRECT use of iv (and of iv+step) is one of {the guard compare,
// the increment, an ElementAddr index, a ZExt/SExt} carries values only in
// [0, BOUND+step], so the whole IV can run at the narrowest width W that holds
// BOUND+step. On the 8-bit target this turns a 4-byte compare + 4-byte
// increment into 1-byte ops (a large per-iteration saving); it is a no-op where
// the IV is already minimal. Values are non-negative, so a signed guard becomes
// its unsigned twin at the narrow width. A ZExt/SExt of the IV keeps the same
// logical value, so those uses stay correct after narrowing; any other direct
// use (which would observe the wide bit pattern) makes the pass bail.
// Profile-gated (narrowsInductionVars) — biggest on xt6502.
@interface XTIROptNarrowIV : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
