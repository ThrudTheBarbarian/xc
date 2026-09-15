#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// Fold a constant-valued RHS operand of Add / Sub / ICmp / And / Or / Xor
// into an immediate operand, so the xt6502 backend emits `ADC #k` / `CMP #k`
// directly instead of materialising the constant into an SP-frame slot and
// loading it back. Traces through ZExt / SExt to the Const def, then
// dead-strips the now-unused Const / extension instructions. -O2+.
@interface XTIROptConstOperandFold : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
