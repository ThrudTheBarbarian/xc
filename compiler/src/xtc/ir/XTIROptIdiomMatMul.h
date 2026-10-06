#import "XTIROptPass.h"

@class XTIROptTargetProfile;

NS_ASSUME_NONNULL_BEGIN

// idiom-matmul — recognise a dense matrix-multiply loop nest
//
//   for (i = 0; i < M; i++)
//     for (j = 0; j < N; j++) {
//       s = 0.0;
//       for (k = 0; k < K; k++) s = s + A[i*lda + k] * B[k*ldb + j];
//       C[i*ldc + j] = s;
//     }
//
// (f32 or f64) and put a call to the SME kernel in front of it:
//
//   %done = Call @__xt_sme_gemm_f32(A, B, C, M | N<<32, K, lda, ldb, ldc)
//   CondBranch %done, <nest exit>, <nest>
//
// The nest stays as the fallback: the kernel returns false on a CPU without
// SME, when C overlaps A or B, or when an index would wrap 32 bits. The
// kernel itself is emitted by the arm64 back end (XTArm64Backend), once per
// module that calls it. Results are bit-identical: the back end fuses
// `s + a*b` into fmadd, and FMOPA is the same fused multiply-add per element,
// in the same k order. arm64 macOS only (smeMatMul), -O2+; runs after
// idiom-memset, before the vectoriser and the unrollers change the nest's
// shape. Design: private:docs/Design/simd-sme-plan.md.
@interface XTIROptIdiomMatMul : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
