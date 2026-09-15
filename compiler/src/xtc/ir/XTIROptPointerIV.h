// XTIROptPointerIV.h — pointer-induction-variable strength reduction.
//
// A loop that indexes arrays at the induction variable —
//
//     H:  iv = phi[PH:0, B:iv+step]; guard iv<N; CondBranch B, E
//     B:  ea = ElementAddr(base, iv);   v = VLoad(ea); …
//         ea2 = ElementAddr(base, iv+vw); … (unrolled copies)
//         iv_next = iv + step
//
// recomputes `base + iv·scale` from scratch every access (and, after unrolling,
// once per copy per array). clang instead carries an advancing *pointer* per
// array: p = phi[PH:base, B:p+step·scale], and each access is `p` (+ a constant
// element offset for an unrolled copy) — so the unrolled copies become
// immediate-offset loads (`ldr q, [p, #16]`) and the per-iteration recurrence is
// a single pointer bump.
//
// This pass introduces those pointer phis: for each loop-invariant array base
// accessed at an affine function of the induction variable (iv, or iv + a
// constant via the unroller's increment chain), it creates a pointer phi
// advancing by step·scale and rewrites the ElementAddrs to `ElementAddr(p,
// constOffset)` (or `p` itself at offset 0). The backend then folds the constant
// element offset into the load/store addressing.
//
// arm64-gated (relies on the flat host-pointer model and the backend immediate-
// offset fold). -O2+, after the unrollers.
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIROptTargetProfile;

@interface XTIROptPointerIV : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
