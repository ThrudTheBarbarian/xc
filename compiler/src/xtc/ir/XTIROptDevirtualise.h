// XTIROptDevirtualise.h — guarded devirtualisation.
//
// A virtual call in a loop whose method has few implementations in the
// program becomes a test of the receiver's class against each class that has
// one, a direct call to that class's method where it matches (which the late
// inliner then inlines), and the virtual call itself where none does. A
// receiver that does not change in the loop is tested once, before the loop,
// and each class gets a copy of the loop with a direct call. The port's
// selfhost/opt/OptDevirt.xc is the same pass.
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIROptTargetProfile;

@interface XTIROptDevirtualise : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
