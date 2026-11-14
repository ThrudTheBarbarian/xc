#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// A float-to-integer conversion whose operand is known finite and in range
// drops its range check (marked XTIRConvUnchecked, the form C's casts take).
// The range is kept in integers: a bound |x| <= 2^E, x >= 0, finite. #23.
@interface XTIROptFloatRange : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
