// XTIROptOuterVectorize.h — vectorise a loop around a reduction loop
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

@class XTIROptTargetProfile;

NS_ASSUME_NONNULL_BEGIN

/// `for j { s = 0; for k { s += f(k, j) } out[.. + j] = g(s) }`, where each
/// load in the k loop is either the same for every j or at an address that
/// moves by one element with j, computes one output cell per j — and four
/// neighbouring cells are four lanes of one vector. The j loop steps by the
/// lane count, the accumulator becomes a vector, a j-independent load is
/// broadcast, a j-contiguous one is a vector load, and the cell store is a
/// vector store. Each lane does exactly the scalar loop's operations in the
/// scalar loop's order, so nothing is reassociated.
///
/// This is the matrix multiply shape: the inner loop is a dot product, which
/// the ordinary vectoriser cannot use, but its neighbours in j are
/// independent.
@interface XTIROptOuterVectorize : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
