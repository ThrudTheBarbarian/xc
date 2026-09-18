// XTIROptTargetProfile.h — per-architecture optimisation tuning.
//
// An opt pass that can be safely more aggressive on one target than another
// asks the target for its limits / capabilities instead of hard-coding a
// single conservative constant. The base class supplies conservative
// defaults (sized for the 6502: small code-growth caps, single induction
// variable, no calls in an unrolled body); a target subclass overrides only
// the knobs it can relax. The pipeline carries one profile and hands it to
// the passes that consult it.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTIROptTargetProfile : NSObject

// ── Loop unrolling ──────────────────────────────────────────────────────
// Largest trip count to fully unroll.
- (NSUInteger)unrollMaxTrip;
// Largest straight-line body (instruction count) eligible to unroll.
- (NSUInteger)unrollMaxBodyInsns;
// Per-function instruction ceiling above which unrolling is skipped.
- (NSUInteger)unrollFnInsnBudget;
// YES to unroll loops that carry more than the induction variable across
// iterations (accumulators / reductions — extra header phis).
- (BOOL)unrollAllowsMultipleCarriedValues;
// YES to unroll a body that contains calls (each copy re-issues the call,
// which is exactly what the trip executions did — safe only where the
// backend emits in program order and doesn't reorder on the memory token).
- (BOOL)unrollAllowsCallsInBody;
// Frame-addressability ceiling for CALL-bearing unrolls: skip a call-body
// unroll that would push the function's total SSA value-id count past this.
// arm64 gives every value an 8-byte slot from sp+16 and a 32-bit slot load/
// store reaches only off ≤ 16380, so > ~2045 ids has unaddressable slots.
- (NSUInteger)unrollMaxFrameValueIds;

// ── Static-init-guard elimination ───────────────────────────────────────
// YES to remove a class's `if(!__sinit_X){…init…}` guard when it is
// dominated by another guard for the same class (the flag is provably
// already set). Pure CFG/SSA redundancy, but the fold leaves the dead
// guard's memory tokens dangling, which is harmless only where the backend
// treats the memory token as advisory (emits loads/stores in program order)
// — so it is opt-in per target.
- (BOOL)eliminatesRedundantInitGuards;

// YES to hoist a class's init guard to the function entry (a conditional
// `if(!__sinit_X){init}` placed once at entry), which dominates — and so
// folds away (see above) — every in-body guard for X. This runs the guard
// once per call instead of per use/iteration and single-blocks loop bodies
// (so the unroller can then reach them). It initialises X eagerly on entry
// rather than at first use; equivalent for an idempotent class init that the
// function unconditionally reaches, so it is opt-in per target.
- (BOOL)hoistsInitGuardsToEntry;

// YES to strength-reduce a library pow(x, 2) call to x*x. Mathematically
// exact, but x*x is not guaranteed bit-identical to a given pow
// implementation for every input, so a target opts in only where it holds
// (the libm sqrt/pow path on arm64 matches; a software float pow may not).
- (BOOL)foldsPowSquare;

// YES if the target has a hardware square-root instruction, so a library
// sqrt[f] call (the `_xm_sqrt[f]` intrinsic) is canonicalised to the IR `FSqrt`
// op and instruction-selected (arm64 `fsqrt`, arm9 VFP `vsqrt`) instead of a
// runtime call. Targets without one (6502, soft-float m68k) keep the call.
- (BOOL)lowersSqrtToHardware;

// YES when the backend lowers the abstract VaStart/VaArg ops to a native AAPCS
// va_list (arm9). The default XTIROptVaArgExpand pass then SKIPS this target,
// leaving the ops for the backend. NO elsewhere → the pack-buffer expansion runs.
- (BOOL)usesNativeVarargs;

// YES to hoist & dedup loop-invariant global-symbol addresses (`AddrOf @sym`)
// to the function entry, so a global accessed across several loops computes its
// base once (homed in a register) instead of re-materialising adrp/add per
// occurrence. Safe anywhere, but only worthwhile where a flat host address is a
// cheap register value and the backend keys element/field strides off the base
// *value's* pointee type (so merges must preserve that type) — i.e. arm64. The
// 6502 AbsSym fast path materialises globals differently and opts out.
- (BOOL)hoistsGlobalAddr;

// YES to partially unroll a *variable*-trip loop (unknown iteration count) by
// replicating its single-block body N times in sequence, each copy guarded by a
// clone of the loop test (so the tail is handled inline — no separate remainder).
// Sound by construction: the copies run the original body / increment / compare
// in the original order, just regrouped so the back-edge fires once per N bodies.
// Worthwhile where the per-iteration branch/increment overhead is a real share
// of a short body (arm64); the 6502 keeps loops rolled to save code space.
- (BOOL)unrollsVariableTrip;

// YES to rewrite a byte-fill loop `for(i=0; i<cmp>bound; i++) arr[i] = C` into a
// single MemSet (→ `bl _memset`, internally vectorised) instead of a scalar
// store loop. arm64 only: the xt6502 memset runtime caps a *runtime* count at
// one byte and a banked-pointer dst has bank-window subtleties, so that target
// keeps its scalar loop (the two backends still fill identically).
- (BOOL)recognisesMemsetIdiom;

// YES to convert self-recursion in tail position into a loop.
//
// Tier 1 (`convertsTailRecursion`) rewrites a true tail self-call
// (`return f(args)`) to a back-edge that reassigns the parameters — the call
// frame for that path disappears. A large measured win on arm64: a linear tail
// recursion of depth N becomes a tight loop, eliminating N call/return pairs and
// stack traffic the OoO core cannot hide (~13× on a depth-4000 accumulator-
// parameter loop). On for arm64, off for the 6502 (its hidden hardware stack
// already makes the call cheap, and the loop form needs phi-resident parameters
// the ZP pin pool doesn't model). Soundness: the new args are a straight
// parameter reassignment (a parameter permutation, which the sequential phi-edge
// copies can't realise, is detected and skipped).
- (BOOL)convertsTailRecursion;

// Tier 2 (`convertsAccumulatorRecursion`) rewrites accumulator recursion
// (`return g ⊕ f(args)` with ⊕ an associative, commutative integer op: +, *, |,
// ^) into a loop that threads an accumulator, so each level makes one recursive
// call instead of two (the classic `fib` transform). OFF everywhere by default:
// on Apple Silicon it measured a ~6% *regression* on naive `fib` — the return-
// address predictor and out-of-order execution already hide the call overhead,
// so trading half the calls for loop/accumulator bookkeeping plus the unrolled
// recursive body is a net loss (the same "instruction count ≠ wall-clock" effect
// behind the reverted arg-mov / loop-rotation tries). The transform is correct
// (oracle-validated) and kept behind this knob for a core whose call overhead is
// NOT hidden. Soundness rests on integer-op associativity (float excluded) and
// the iterated call being the last memory op before the return.
- (BOOL)convertsAccumulatorRecursion;

// YES to auto-vectorise a simple elementwise map loop — a constant-trip
// (multiple of the vector width) loop whose body loads from arrays at the
// induction index, applies pure elementwise integer arithmetic, and stores back
// at the same index — into 128-bit NEON SIMD (4×i32/lane), processing four
// elements per iteration. arm64 only (the SIMD lowering is NEON); sound because
// each element/lane is independent (same-index access ⇒ no cross-lane hazard,
// aliasing-immune) and integer 2's-complement lane ops match the scalar result.
- (BOOL)vectorizesLoops;

// YES to rotate a top-tested loop into a bottom-tested one: the loop's exit test
// is peeled into the preheader (run once) and duplicated at the bottom of the
// body, so the back-edge becomes a single conditional branch (cbnz) instead of a
// header cbz-to-exit plus an unconditional `b` back to the header — one fewer
// branch instruction per iteration, matching clang's loop shape (measured ~2× on
// a tight strlen/counted loop). arm64 only: a flat ISA where the extra branch is
// the cost; the 6502's loops are dominated by other overheads. Sound: the peeled
// test reads exactly what the original header read on entry, and the guard is
// duplicated only when side-effect-free.
- (BOOL)rotatesLoops;

// YES to if-convert a short-circuit / predicate diamond into branchless
// straight-line boolean algebra. A header CondBranch whose taken arm is a
// single, provably side-effect-free block that only computes values and falls
// through to the join (the shape that `a && b`, `a || b`, and `if (c) x = v;`
// lower to) collapses to a `Select` per join phi — removing the branches and,
// critically, the cross-block boolean temporaries that otherwise spill/reload
// every iteration. arm64 only: it has `csel` and a flat register file where
// branchless wins; the 6502 has neither and keeps the branches. Soundness rests
// on the speculated arm being pure and trap-free (no load/store/call/div).
- (BOOL)ifConvertsPredicates;

// May a callee taking an aggregate BY VALUE be inlined? Such a parameter is
// only read through AddrOf(param), which after inlining becomes AddrOf of the
// caller's LOADED Agg temp. That is not reliably addressable on the 6502 — it
// once harvested zeros (struct_return_field) — so the base answer is NO, and a
// target whose aggregates are ordinary addressable memory overrides it.
- (BOOL)inlinesAggregateParams;

// YES to hoist loop-invariant instructions to the loop preheader (pure address /
// arithmetic always; a field Load only when the loop writes no memory, so the
// hoisted load is bounds-safe and reads unchanged memory). arm64 only — the
// 6502's banked-memory loads carry bank-register context that this IR-level move
// doesn't model, so that target keeps loads in place.
- (BOOL)hoistsLoopInvariants;

// YES to form pointer induction variables: replace a loop array access
// `base + iv·scale` with an advancing pointer phi (p += step·scale per
// iteration), so unrolled copies become immediate-offset loads and the address
// recurrence is one pointer bump. arm64 only — relies on the flat host-pointer
// model and the backend folding the constant element offset into the load.
- (BOOL)formsPointerInductionVars;

// YES to collapse an invariant reduction nest: an outer counted loop (constant
// trip T) whose only loop-carried value (beside its induction variable) is an
// accumulator `acc += delta` where `delta` is invariant across the outer loop —
// including a `delta` produced by a nested inner reduction loop reading only
// outer-invariant arrays. The outer loop is replaced by computing `delta` once
// and closing the form `acc += T·delta` (clang hoists the whole invariant inner
// loop out of such a rep loop; xtc otherwise recomputes it every outer
// iteration). arm64 only during bring-up. Soundness rests on the accumulate op
// being associative/commutative over 2's-complement integers (+, so T·delta
// mod 2^w equals T repeated adds) and the outer body writing no memory the
// outer loop re-reads (a distinct-symbol read/write-set check).
- (BOOL)collapsesInvariantReductions;

// Narrow a counted loop's induction variable to the smallest width that holds
// its range (bound + step), when every direct use is the guard compare, the
// increment, an ElementAddr index, or a width cast. Turns a 4-byte compare +
// increment into 1-byte ops on the 8-bit target; a no-op where the IV is
// already minimal. Semantics-preserving on every backend; biggest on xt6502.
- (BOOL)narrowsInductionVars;

// The conservative profile (the base defaults). Used by the 6502 / generic
// pipeline and anywhere a target hasn't been specified.
+ (instancetype)conservativeProfile;

@end

// arm64 has 31 registers, a clean ISA and no 16 KB code-bank limit, so it
// relaxes every unroll knob the 6502 keeps tight.
@interface XTIRArm64TargetProfile : XTIROptTargetProfile
@end

// m68k (Atari ST/TT) has 16 registers and no 16 KB code-bank limit, so it can
// relax the unroll knobs the 6502 keeps tight. It stays conservative on the
// arm64-only transforms (vectorisation, if-conversion, pointer-IV) until the
// 68k backend can lower the IR they produce.
@interface XTIRM68kTargetProfile : XTIROptTargetProfile
@end

// arm9 (ARMv7-A / Cortex-A9): conservative like the base during bring-up, but its
// VFP has a hardware `vsqrt`, so it opts into the FSqrt instruction-selection path.
@interface XTIRArm9TargetProfile : XTIROptTargetProfile
@end

// x86-64 (System V AMD64, Linux/musl): conservative base during bring-up. Has a
// hardware sqrt (SSE `sqrtsd`), so it opts into the FSqrt path; native AAPCS-style
// va_list (System V register save area), so it uses native varargs.
@interface XTIRX86_64TargetProfile : XTIROptTargetProfile
@end

// wasm32 (WebAssembly). The ENGINE does register allocation and instruction
// selection, so the profile keeps the semantic transforms (LICM, if-convert →
// `select`, memset → `memory.fill`, sqrt → `f32/f64.sqrt`, tail-recursion →
// loop — wasm has no growable native stack) and skips the machine-level ones
// (register homing has no registers to home; a data address is already an i32
// constant, so no global-addr hoist). Unroll caps stay modest: code size is
// download size. private:docs/Design/wasm-target.md §9 is the decision table.
@interface XTIRWasm32TargetProfile : XTIROptTargetProfile
@end

// xt6502 (banked 6502). The default is -O3, so this profile turns ON the
// size-reducing transforms that help code fit the tight unbanked region —
// static-init-guard hoist/dedup (34 inlined guards -> one per class at entry)
// and global-address hoist (kills repeated `&__sdata` materialisation). It
// keeps the conservative unroll caps (a 16 KB code bank can't absorb large
// unrolls) and leaves the arm64-only transforms (vectorise / pointer-IV) off.
@interface XTIRXt6502TargetProfile : XTIROptTargetProfile
@end

NS_ASSUME_NONNULL_END
