#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// Demanded-width narrowing. When a wide arithmetic result is immediately
// truncated to a narrower width W — `Trunc_W(Op(x, y))` for an Op whose low W
// bits depend only on the operands' low W bits (Add/Sub/Mul/And/Or/Xor) — the
// discarded high bits are dead, so the Op is recomputed at width W on the
// W-narrowed operands. A `Trunc_W(ZExt/SExt from a W-wide source)` operand
// collapses to the source, so the classic `u16 y = a*b` (which integer
// promotion lowers to `Trunc_16(Mul_32(ZExt a, ZExt b))`) folds straight back
// to a 16-bit multiply — the promotion costs nothing where the result is
// narrowed, while `u32 x = a*b` keeps its wide multiply. Runs at every -O
// level: it is a pure size/speed win on every backend and is what makes C-style
// integer promotion free on the 8-bit target.
@interface XTIROptNarrow : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
