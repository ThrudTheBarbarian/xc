#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// A value retained and then released, with nothing between them that can free
// or change anything (no call, no store, no other release), keeps the count it
// had: the pair does nothing and both go. The release may name the value
// through casts, or through the phi a downcast leaves (the cast value, or null
// on the edge taken when the value is null). Every path from the retain must
// reach the release, or end in Unreachable, without a Return and without
// coming round to the retain again. The port's Opt.arcPairElide.
@interface XTIROptArcPair : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
