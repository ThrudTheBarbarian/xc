#import "XTIROptPass.h"
#import "XTIROptTargetProfile.h"

NS_ASSUME_NONNULL_BEGIN

// Strength reduction of integer multiply / divide / remainder by a
// compile-time constant. Runs on the shared IR, so BOTH backends benefit.
//
//   Mul  x, 2^k   → Shl  x, k        (signed and unsigned: same low bits)
//   Mul  x, 0     → Const 0
//   UDiv x, 2^k   → LShr x, k        (UNSIGNED only)
//   URem x, 2^k   → And  x, 2^k-1    (UNSIGNED only)
//   URem x, 1     → Const 0
//   SRem x, 1     → Const 0
//
// Signed divide/remainder by a power of two is deliberately NOT reduced —
// truncation toward zero needs a sign-bias add/shift sequence, which is
// more code and easy to get wrong, so those stay as the runtime call. The
// x*1 / x/1 → x identities are also skipped: the xt6502 backend has no Copy
// lowering, and forwarding x would need a use-rewrite (the CSE pass's job).
// The constant operand is resolved through ZExt/SExt of a Const (the form
// the lowering emits for a widened literal). -O2+.
//
// The float rewrites, all exact (see runFloatOnFunction:):
//   FDiv x, ±2^e  → FMul x, ±2^-e   (1/c a normal number of the type)
//   FMul x, 2     → FAdd x, x       (profile.floatMulToAdd)
//   FAdd (FMul x, -2), c → FSub c, (FAdd x, x)   (likewise)
@interface XTIROptStrengthReduce : NSObject <XTIROptPass>
// Set by the main pipeline; nil (a par kernel's passes) leaves the multiply
// rewrites off.
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
