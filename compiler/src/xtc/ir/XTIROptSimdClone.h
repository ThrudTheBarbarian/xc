// XTIROptSimdClone.h — runtime SIMD dispatch: the per-level clones.
//
// Under `-msimd=auto` the vectorised functions are built once per vector
// level and the runtime picks one at load (private:docs/Design/simd-dispatch.md).
// The pass runs twice: CLONE, before the vectorisers, copies each function
// with a loop as `<name>$avx2` with a 32-byte lane width; PRUNE, after them,
// drops every clone that did not vectorise at 32 bytes and marks the function
// a surviving clone came from as dispatched.
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"
#import "XTIROptTargetProfile.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTIROptSimdClone : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@property(nonatomic) BOOL prune; // NO: clone, YES: prune
@end

NS_ASSUME_NONNULL_END
