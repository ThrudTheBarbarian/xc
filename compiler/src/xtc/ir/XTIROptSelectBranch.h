// XTIROptSelectBranch.h — a float Select whose arm computes becomes a branch (#22)
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIROptTargetProfile;

// If-conversion makes every small diamond a Select. In a loop, a float Select
// on one bit of a value (`(h & 2) != 0 ? 0 - u : u`) makes every iteration
// wait for that value and computes both arms; a branch is predicted and runs
// the arm's arithmetic only when taken (GCC's form for perlin's grad). Late,
// after the inliner and every loop pass, such a Select becomes a branch
// around the arithmetic only its arm uses, and a phi. As the port's
// select-branch (selfhost/opt/OptSelectBranch.xc), block for block.
@interface XTIROptSelectBranch : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
