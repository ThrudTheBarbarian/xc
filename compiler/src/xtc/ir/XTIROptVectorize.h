// XTIROptVectorize.h — elementwise-map loop auto-vectorisation (arm64/NEON).
//
// Recognises a constant-trip (multiple of the vector width) loop whose body is a
// pure elementwise map over arrays indexed by the induction variable:
//
//     for (i = 0; i < N; i++)   // N const, N % 4 == 0, step 1
//         a[i] = <pure int arithmetic over b[i], c[i], …, constants>;
//
// and rewrites it to process four i32 lanes per iteration via 128-bit SIMD: each
// scalar Load/Store/arith becomes a VLoad/VStore/V<op>, scalar constants/
// invariants are VSplat-broadcast, and the induction step becomes 4. Sound
// because every lane (index i) is independent — same-index access has no cross-
// lane dependency and is immune to aliasing — and integer 2's-complement lane
// arithmetic matches the scalar result bit-for-bit.
//
// Profile-gated (arm64 on), -O2+, runs before the unrollers (which would
// otherwise replicate the scalar body). First cut: i32/u32 lanes, single
// induction variable (no reduction), constant trip divisible by 4.
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

@class XTIROptTargetProfile;

NS_ASSUME_NONNULL_BEGIN

@interface XTIROptVectorize : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
