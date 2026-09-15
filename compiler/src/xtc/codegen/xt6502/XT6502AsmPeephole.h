#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// xt6502 backend peephole — runs over the asm-text output of
// XT6502Backend to close obvious gaps left by the naive "every SSA
// value goes through a stack slot" lowering. Designed specifically
// for the backend's instruction shapes (PSH/PLL frame, +d,SP
// stack-relative addressing, (+d,SP),Y indirection).
//
// Each pass takes an asm string and returns a transformed one. Passes
// are run in sequence by `+optimise:level:` until a fixed point or
// until a hop budget is exhausted (some rules can enable others).
//
// Safety model: every rule preserves observable semantics — values in
// A/X/Y when control reaches the next labelled point, memory writes,
// flag state at conditional branches. Rules document any flag
// assumptions inline.
@interface XT6502AsmPeephole : NSObject

/// Apply peephole rules at the requested level.
///   0 → return input unchanged
///   1 → redundant-reload elimination
///   2 → +1 ... (placeholder for future rules)
///   3 → +2 ...
+ (NSString*)optimise:(NSString*)asmText level:(NSInteger)level;

@end

NS_ASSUME_NONNULL_END
