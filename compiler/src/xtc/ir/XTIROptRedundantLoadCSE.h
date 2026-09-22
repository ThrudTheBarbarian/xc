#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// Intra-block local value numbering + redundant-load elimination.
//
// Two transforms, both block-local (state reset at every block boundary,
// so no dominance/aliasing reasoning across edges is needed):
//
//   * Pure-op CSE — a pure, deterministic, memory-free op (arithmetic,
//     bitwise, shifts, casts, compares, Select, and the address ops
//     AddrOf/FieldAddr/ElementAddr) whose (opcode, predicate, result-type,
//     operands) match an earlier result in the same block reuses that
//     result. Operands are canonicalised through prior CSE decisions, so a
//     single top-down pass folds chains (dedup an AddrOf → the FieldAddrs
//     off it dedup too).
//
//   * Redundant-load elimination — a non-volatile Load from a pointer
//     already loaded in this block, with no memory-writing or opaque op
//     since (any TouchesMemory op other than a plain Load, plus bank-state
//     ops, clears the cache), reuses the earlier loaded value. The deleted
//     Load's memory token is rewired to its own mem-in operand (a Load
//     doesn't change memory, and nothing wrote between the two loads, so
//     the tokens are equivalent).
//
// Benefits BOTH backends (it runs on the shared IR before codegen). -O2+.
/// Cross-block availability (see the .m). OFF by default: it creates uses whose
/// definition lives in a DOMINATING block, and the loop cloner in the
/// vectoriser assumes every value a body uses is defined in that body — a
/// clone then references a definition that does not dominate it. matrix_mul
/// computed 63968 instead of 2046976 with this on before the vectoriser.
/// Enabled only on the instance that runs before if-conversion, which is where
/// it pays: it is what makes a diamond's arms convertible.
@interface XTIROptRedundantLoadCSE : NSObject <XTIROptPass>
@property(nonatomic) BOOL crossBlock;
@end

NS_ASSUME_NONNULL_END
