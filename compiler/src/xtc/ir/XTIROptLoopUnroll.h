#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIROptTargetProfile;

// Full unrolling of small constant-trip-count loops, on the shared IR (so
// both backends benefit). Recognises the canonical counted-loop shape the
// lowering emits — a header block with a single induction-variable Phi, an
// ICmp of the iv against a constant bound, and a CondBranch to a single
// straight-line body block that increments the iv by a constant and
// branches back — and replaces it with `trip` copies of the body, the iv
// substituted by its constant value in each copy, wired entry → c0 → c1 →
// … → exit. The loop control (phi, compare, branch) disappears.
//
// Deliberately narrow to stay correct and to bound code growth (unrolling
// inflates code, which on the bank-limited 6502 can overflow a code bank):
//   * trip count 2..4, body ≤ 8 instructions;
//   * exactly one header phi (the iv); no accumulator phis — loop-carried
//     state must live in memory, not SSA;
//   * body is a single block, the loop's only latch, with no calls / inline
//     asm / mem-copy/set / aggregate or volatile memory ops and no nested
//     control flow;
//   * the iv is not used after the loop, and the exit block has no phi.
// When unrolling a qualifying loop would push the function past a
// conservative size budget it is SKIPPED with a warning rather than risk a
// code-bank overflow. -O2+.
//
// The trip / body / budget caps and two capability switches (carry more than
// the iv across iterations; allow calls in the body) come from the target
// profile, so a register-rich, bank-free target (arm64) can unroll
// multi-accumulator and call-bearing straight-line loops the 6502 can't.
// With the conservative (default) profile the behaviour is exactly the
// single-iv / no-calls form described above.
@interface XTIROptLoopUnroll : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
