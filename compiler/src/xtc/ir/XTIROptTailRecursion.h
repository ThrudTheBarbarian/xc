// XTIROptTailRecursion.h — recursion → loop transformation.
//
// Converts self-recursion in tail position into an in-function loop, so the
// per-call prologue/epilogue (and, for the accumulator case, half the calls)
// disappear:
//
//   Tier 1 — true tail self-call. `return f(args);` (the call result is
//            returned directly) becomes a back-edge that reassigns the
//            parameters and re-enters the body. The frame for that path is
//            gone entirely.
//
//   Tier 2 — accumulator recursion. `return g ⊕ f(args);` where ⊕ is an
//            associative, commutative integer op (+, *, |, ^) and the self
//            call is the last memory operation before the return, becomes a
//            loop threading an accumulator (acc = acc ⊕ g; loop with the new
//            args). Each iteration makes ONE recursive call instead of two —
//            the classic `fib(n-1)+fib(n-2)` halving that closes the gap to
//            clang.
//
// Profile-gated (arm64 on, 6502 off) and -O2+. Soundness rests on the combine
// being genuinely associative over 2's-complement integers (float is rejected)
// and on the iterated call being the function's last side effect on that path,
// which keeps the side-effect order identical to the recursion.
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

@class XTIROptTargetProfile;

NS_ASSUME_NONNULL_BEGIN

@interface XTIROptTailRecursion : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
