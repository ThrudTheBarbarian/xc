// XTIROptReassociate.h — shorten a loop-carried reduction chain
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

/// An unrolled reduction is a chain, `acc + x0 + x1 + x2 + x3`, and every link
/// of it waits for the one before: four dependent adds per iteration on the
/// value the loop carries. For an associative integer op the chain can be
/// rebuilt as `acc + ((x0 + x1) + (x2 + x3))`, which leaves ONE op on the
/// carried value per iteration and does the rest in parallel. Integer only —
/// wrapping add, mul and the bitwise ops reassociate exactly; float does not.
@interface XTIROptReassociate : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
