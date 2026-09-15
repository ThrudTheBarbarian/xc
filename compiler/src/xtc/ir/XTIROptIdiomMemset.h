#import "XTIROptPass.h"

@class XTIROptTargetProfile;

NS_ASSUME_NONNULL_BEGIN

// Byte-fill idiom recognition: a single-block loop
//   for (i = 0; i <cmp> BOUND; i++) arr[i] = CONST;   // BOUND, CONST compile-time
// over a 1-byte-element array is rewritten to one MemSet (→ `bl _memset`,
// internally vectorised) and the loop is deleted. Profile-gated
// (recognisesMemsetIdiom — arm64 only). Runs before the unrollers (so the fill
// loop becomes a memset rather than being unrolled). -O2+.
@interface XTIROptIdiomMemset : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
