#import "XTIROptPass.h"

@class XTIROptTargetProfile;

NS_ASSUME_NONNULL_BEGIN

// Loop-invariant code motion. Hoists instructions whose operands are all defined
// outside a loop to the loop's preheader, so they run once instead of every
// iteration. Pure ops (address arithmetic, integer arithmetic, casts, compares)
// hoist freely; a Load hoists only when it is a FIELD load (FieldAddr base, so
// bounds-safe on a live object even if the loop runs zero times) and the loop
// writes no memory and makes no call (so the load reads unchanged memory). The
// motivating case: an `arr.get(i)` traversal reloads the array's backing-buffer
// pointer every iteration; LICM keeps it in a register like C++. Profile-gated
// (hoistsLoopInvariants — arm64 only). -O2+.
@interface XTIROptLICM : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
