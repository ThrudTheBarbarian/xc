// XTIROptPowSquare.h — strength-reduce pow(x, 2) to x*x.
//
// A call to the library power method with a compile-time exponent of 2
// (Math$pow__<ftype>_i16/i32/u32 with the exponent resolving to the constant
// 2) is replaced by a single floating multiply. pow is pure, so the call's
// memory token is forwarded to its memory input. -O2+, profile-gated: x*x is
// not guaranteed bit-identical to a libm/software pow(x,2) for every input,
// so a target opts in only where that holds (validated by the differential
// sweep). Runs before the inliner, while the call is still the wrapper.
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIROptTargetProfile;

@interface XTIROptPowSquare : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
