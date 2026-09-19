#import "XTIROptTargetProfile.h"

@implementation XTIROptTargetProfile

// Off by default: measured on arm64, and it produces wrong answers on xt6502.
- (BOOL)hoistsLocalAddr
    {
    return NO;
    }

// Unrolled size cap (trip x body). 0 is no cap, which is what every profile
// that has not measured one gets.
- (NSUInteger)unrollMaxTotalInsns
    {
    return 0;
    }

- (BOOL)inlinesAggregateParams
    {
    return NO;   // 6502-conservative base
    }

// Conservative defaults — these are exactly the constants the loop-unroll
// pass shipped with (sized so unrolling can't tip a 6502 code bank), so a
// target that doesn't override anything behaves identically to before.
- (NSUInteger)unrollMaxTrip
    {
    return 4;
    }
- (NSUInteger)unrollMaxBodyInsns
    {
    return 8;
    }
- (NSUInteger)unrollFnInsnBudget
    {
    return 512;
    }
- (BOOL)unrollAllowsMultipleCarriedValues
    {
    return NO;
    }
- (BOOL)unrollAllowsCallsInBody
    {
    return NO;
    }
- (NSUInteger)unrollMaxFrameValueIds
    {
    return NSUIntegerMax;
    }
- (BOOL)eliminatesRedundantInitGuards
    {
    return NO;
    }
- (BOOL)hoistsInitGuardsToEntry
    {
    return NO;
    }
- (BOOL)foldsPowSquare
    {
    return NO;
    }
- (BOOL)lowersSqrtToHardware
    {
    return NO;
    }
- (BOOL)usesNativeVarargs
    {
    return NO;
    }
- (BOOL)hoistsGlobalAddr
    {
    return NO;
    }
- (BOOL)unrollsVariableTrip
    {
    return NO;
    }
- (BOOL)recognisesMemsetIdiom
    {
    return NO;
    }
- (BOOL)hoistsLoopInvariants
    {
    return NO;
    }
- (BOOL)convertsTailRecursion
    {
    return NO;
    }
- (BOOL)convertsAccumulatorRecursion
    {
    return NO;
    }
- (BOOL)ifConvertsPredicates
    {
    return NO;
    }
- (BOOL)rotatesLoops
    {
    return NO;
    }
- (BOOL)vectorizesLoops
    {
    return NO;
    }

- (BOOL)vectorizesHighMultiply
    {
    return NO;
    }
- (BOOL)formsPointerInductionVars
    {
    return NO;
    }
- (BOOL)collapsesInvariantReductions
    {
    return NO;
    }
- (BOOL)narrowsInductionVars
    {
    return NO;
    }

+ (instancetype)conservativeProfile
    {
    return [[self alloc] init];
    }

@end

@implementation XTIRArm64TargetProfile

- (BOOL)inlinesAggregateParams
    {
    return YES;   // aggregates are ordinary addressable memory
    }

- (NSUInteger)unrollMaxTrip
    {
    return 32;
    }
- (NSUInteger)unrollMaxBodyInsns
    {
    return 64;
    }
// A fully unrolled loop is ONE basic block, and every value it computes is
// live inside it. matrix_mul's k loop is trip 32 over a 9-instruction body:
// unrolled whole that is ~290 instructions and ~160 short-lived values in a
// single block, far past the register pool, so every one of them round trips
// through the frame. Measured, that loop runs 9.8ms fully unrolled and 3.1ms
// not — a 3x LOSS from unrolling more.
//
// The trip count alone does not say this: trip 32 over a 2-instruction body
// is fine. The product does, because it is what the allocator sees.
- (BOOL)hoistsLocalAddr
    {
    return YES;
    }
- (NSUInteger)unrollMaxTotalInsns
    {
    return 128;
    }
- (NSUInteger)unrollFnInsnBudget
    {
    return 8192;
    }
- (BOOL)unrollAllowsMultipleCarriedValues
    {
    return YES;
    }
// EXPERIMENTAL (A/B): unroll call bodies via the transient memory phi in
// XTIROptLoopUnroll. Frame-gated by unrollMaxFrameValueIds below.
- (BOOL)unrollAllowsCallsInBody
    {
    return YES;
    }
- (NSUInteger)unrollMaxFrameValueIds
    {
    return 1900;
    }
- (BOOL)eliminatesRedundantInitGuards
    {
    return YES;
    }
- (BOOL)hoistsInitGuardsToEntry
    {
    return YES;
    }
- (BOOL)foldsPowSquare
    {
    return YES;
    }
- (BOOL)lowersSqrtToHardware
    {
    return YES;
    }
- (BOOL)hoistsGlobalAddr
    {
    return YES;
    }
- (BOOL)unrollsVariableTrip
    {
    return YES;
    }
- (BOOL)recognisesMemsetIdiom
    {
    return YES;
    }
- (BOOL)hoistsLoopInvariants
    {
    return YES;
    }
- (BOOL)convertsTailRecursion
    {
    return YES;
    }
// Off: measured a ~6% regression on naive fib (call overhead already hidden by
// the OoO core's return-address predictor). Kept available; see the header.
- (BOOL)convertsAccumulatorRecursion
    {
    return NO;
    }
- (BOOL)ifConvertsPredicates
    {
    return YES;
    }
- (BOOL)rotatesLoops
    {
    return YES;
    }
- (BOOL)vectorizesLoops
    {
    return YES;
    }

// umull/umull2 + uzp2 build the high half of a 32x32 lane product and
// ushr does the post-shift, so constant division vectorises here.
- (BOOL)vectorizesHighMultiply
    {
    return YES;
    }
- (BOOL)formsPointerInductionVars
    {
    return YES;
    }
- (BOOL)collapsesInvariantReductions
    {
    return YES;
    }
// Native AAPCS va_list (bug 179): the backend lowers VaStart/VaArg from the
// incoming stack (Apple's rule — all variadic args on the stack), so the
// pack-buffer expand pass is skipped, exactly as arm9 does.
- (BOOL)usesNativeVarargs
    {
    return YES;
    }

@end

@implementation XTIRXt6502TargetProfile

// Keep the conservative unroll caps (the 6502's 16 KB code bank can't absorb a
// large unroll) — so DON'T override unrollMaxTrip / unrollMaxBodyInsns / etc.
// Turn ON the size-reducing transforms that help code fit, all proven on m68k:
- (BOOL)eliminatesRedundantInitGuards
    {
    return YES;
    }
- (BOOL)hoistsInitGuardsToEntry
    {
    return NO;
    }
- (BOOL)hoistsGlobalAddr
    {
    return YES;
    }
// memset stays OFF: the 6502 backend DOES lower XTIROpMemSet (→ __xtc_memset),
// but it measured insn-count-neutral (a byte-per-store routine does the same
// work as the inline fill loop — it's a code-size play, not a perf win).
- (BOOL)recognisesMemsetIdiom
    {
    return NO;
    }
// Pure CFG/SSA transforms (no new ops) + if-convert (the 6502 backend lowers
// Select). Size-neutral or size-reducing, so they suit the 16 KB code bank.
// Enabled for the perf campaign (phase-565+).
// BISECT: LICM back on
- (BOOL)hoistsLoopInvariants
    {
    return YES;
    }
- (BOOL)convertsTailRecursion
    {
    return YES;
    }
// rotate stays OFF on xt6502 — now for PERF, not correctness. The #569
// miscompile (rotating the collapsed rep-loop remnant read the accumulator as
// garbage) was the rotate-pass exit-phi dangling-reference bug, FIXED in #571;
// with that fix all kernels' checksums agree with rotate on. But measured, it is
// a net LOSS on the 6502 (fill +26%, map +6%, reduce/dot +3-5%): the peeled
// guard the rotation duplicates costs more than the saved back-edge test on a
// byte-addressed machine. So it stays off as a perf choice (campaign-572).
- (BOOL)rotatesLoops
    {
    return NO;
    }
- (BOOL)ifConvertsPredicates
    {
    return YES;
    }
// Arm64-only transforms (need IR the 6502 backend doesn't lower) stay off:
- (BOOL)vectorizesLoops
    {
    return NO;
    }
// pointer-IV measured +4.6-5.6% on map/fill — the 6502 backend has no address
// registers, so the ZP walking-pointer + per-iter advance costs more than the
// scaled-index base reload it replaces. Stays off (campaign-566, measured).
- (BOOL)formsPointerInductionVars
    {
    return NO;
    }
// campaign: huge on rep-loop reductions
- (BOOL)collapsesInvariantReductions
    {
    return YES;
    }
// campaign: 4-byte IV → 1-byte
- (BOOL)narrowsInductionVars
    {
    return YES;
    }
// Accumulator recursion → loop. Off on the OoO natives (a hidden call cost), but
// the in-order 6502 pays every prologue/epilogue/return in full — measured
// −18% on n+rsum(n-1). It also caps stack growth on the small hardware stack.
// campaign: in-order win
- (BOOL)convertsAccumulatorRecursion
    {
    return YES;
    }

@end

@implementation XTIRM68kTargetProfile

// Moderate unrolling — more headroom than the 6502, but no call-body unroll
// or variable-trip until the backend's memory model and codegen are proven.
- (NSUInteger)unrollMaxTrip
    {
    return 16;
    }
- (NSUInteger)unrollMaxBodyInsns
    {
    return 32;
    }
- (NSUInteger)unrollFnInsnBudget
    {
    return 4096;
    }
- (BOOL)unrollAllowsMultipleCarriedValues
    {
    return YES;
    }
- (BOOL)eliminatesRedundantInitGuards
    {
    return YES;
    }
- (BOOL)hoistsInitGuardsToEntry
    {
    return YES;
    }
- (BOOL)hoistsGlobalAddr
    {
    return YES;
    }
// Variable-trip unroll is KERNEL-DEPENDENT on m68k, so it stays off as the
// safer default. It HELPS a register-light arithmetic loop (measured −10% on
// `for i<n: s+=i*3`), but the extra live values an unrolled body carries spill
// on the 68000's eight data registers, so it REGRESSED the spill-heavy array
// reductions (map +16%, reduce +10%). Net across the kernel mix is negative;
// a body-size / register-pressure heuristic could re-enable it selectively.
// (On xt6502 it is moot: every value already lives in an SP-frame slot, so
// duplicating the body only multiplies slot traffic — the pass finds nothing
// worth unrolling even with relaxed caps.)
- (BOOL)unrollsVariableTrip
    {
    return NO;
    }
// NOTE: recognisesMemsetIdiom stays OFF — the m68k backend does not lower
// XTIROpMemSet, so the pass would miscompile byte-fill loops. (campaign-566)
// Pure CFG/SSA transforms — they restructure existing IR without emitting any op
// the backend can't already lower. Enabled for the perf campaign (phase-565+).
- (BOOL)hoistsLoopInvariants
    {
    return YES;
    }
- (BOOL)convertsTailRecursion
    {
    return YES;
    }
- (BOOL)rotatesLoops
    {
    return YES;
    }
// if-convert emits Select, which the m68k backend lowers — enable it too.
- (BOOL)ifConvertsPredicates
    {
    return YES;
    }
- (BOOL)vectorizesLoops
    {
    return NO;
    }
// campaign: try
- (BOOL)collapsesInvariantReductions
    {
    return YES;
    }
// Pointer induction vars: a loop's scaled-index array walks become a walking
// pointer phi advanced by a constant each iteration. The m68k backend homes the
// walking pointer in an address register (a2-a4), loads via (aN), and advances
// it in place with adda — eliminating the per-iteration base reload the
// scaled-index form needs. (See detectPointerIVsForFunction:.)
- (BOOL)formsPointerInductionVars
    {
    return YES;
    }
// campaign: narrower compare/incr
- (BOOL)narrowsInductionVars
    {
    return YES;
    }
// Accumulator recursion → loop: the in-order 68000 pays full call overhead, so
// converting recursion to a loop is a big win — measured −49% on n+rsum(n-1).
// campaign: in-order win
- (BOOL)convertsAccumulatorRecursion
    {
    return YES;
    }

@end

@implementation XTIRArm9TargetProfile
// Cortex-A9 (ARMv7-A, AArch32): a flat 32-bit target with 16 GP registers, VFP,
// and no code-bank limit. Opts into the hardware-sqrt path (VFP `vsqrt`) and the
// native AAPCS va_list (the backend lowers VaStart, so the pack-buffer expand
// pass is skipped and Stdio.printf forwards to libc vprintf).
- (BOOL)lowersSqrtToHardware
    {
    return YES;
    }
- (BOOL)usesNativeVarargs
    {
    return YES;
    }

// ── Enabled for arm9 (each bisected against a deterministic arm9-corpus sweep:
// 279/330 fixtures, ZERO regressions vs the previous baseline). Pure CFG/SSA
// transforms the backend lowers verbatim (Branch/CondBranch/Phi/arith/Call),
// plus lowering-dependent ones the backend supports: if-conversion → Select
// (conditional moves), pointer-IV (advancing pointer phi via add), global-addr
// hoist (strides key off the pointee type), pow(x,2) → VFP vmul, byte-fill →
// bl memset (libc), and moderate loop unrolling (const- and var-trip, with
// reduction accumulators). Unroll caps are m68k-like — the naive slot-per-value
// emitter grows frames fast, so keep them moderate to hold most slot accesses in
// the cheap ldr/str [sp,#imm] form.
- (BOOL)eliminatesRedundantInitGuards
    {
    return YES;
    }
- (BOOL)hoistsInitGuardsToEntry
    {
    return YES;
    }
- (BOOL)convertsTailRecursion
    {
    return YES;
    }
- (BOOL)hoistsLoopInvariants
    {
    return YES;
    }
- (BOOL)rotatesLoops
    {
    return YES;
    }
- (BOOL)hoistsGlobalAddr
    {
    return YES;
    }
- (BOOL)foldsPowSquare
    {
    return YES;
    }
- (BOOL)recognisesMemsetIdiom
    {
    return YES;
    }
- (BOOL)formsPointerInductionVars
    {
    return YES;
    }
- (BOOL)ifConvertsPredicates
    {
    return YES;
    }
- (NSUInteger)unrollMaxTrip
    {
    return 16;
    }
- (NSUInteger)unrollMaxBodyInsns
    {
    return 32;
    }
- (NSUInteger)unrollFnInsnBudget
    {
    return 4096;
    }
- (BOOL)unrollAllowsMultipleCarriedValues
    {
    return YES;
    }
- (BOOL)unrollsVariableTrip
    {
    return YES;
    }
// Auto-vectorise to the Zynq-7000 Cortex-A9's NEON unit. The vectoriser's IR is
// target-neutral; XTArm9Backend lowers it to aarch32 Advanced SIMD (vld1.16 /
// vmul.i16 / vadd.i16 / vpaddl.u16 / vpadd.i32 …) in q8-q15, and .fpu neon is
// emitted. Verified on the Zynq qemu: map/reduce/dot match the arm64 results.
- (BOOL)vectorizesLoops
    {
    return YES;
    }

// LEFT OFF (verified to regress arm9):
//   • collapsesInvariantReductions — its trip-1 rewrite + reduction-nest CFG
//     surgery mis-lowers here (correct on arm64/x86_64), breaking arr_slice_length
//     and mul_u8u8;
//   • unrollAllowsCallsInBody — experimental even on arm64.
// Collapse-lowering is future arm9-backend work.
@end

@implementation XTIRWasm32TargetProfile

// wasm32: the engine's JIT does regalloc + isel, so keep the semantic wins and
// skip machine-level lowering. Full table + rationale: wasm-target.md §9.
- (BOOL)hoistsLoopInvariants
    {
    return YES;
    }
// code size = download size
- (BOOL)eliminatesRedundantInitGuards
    {
    return YES;
    }
- (BOOL)hoistsInitGuardsToEntry
    {
    return YES;
    }
// maps to `select`
- (BOOL)ifConvertsPredicates
    {
    return YES;
    }
// `memory.fill` is one insn
- (BOOL)recognisesMemsetIdiom
    {
    return YES;
    }
// f32.sqrt / f64.sqrt
- (BOOL)lowersSqrtToHardware
    {
    return YES;
    }
// no growable native stack
- (BOOL)convertsTailRecursion
    {
    return YES;
    }
// canonical form for the recognisers
- (BOOL)rotatesLoops
    {
    return YES;
    }
// f64.mul is IEEE
- (BOOL)foldsPowSquare
    {
    return YES;
    }
// Not wanted here (§9): the engine strength-reduces and schedules itself.
// linear-memory cursor is simpler
- (BOOL)usesNativeVarargs
    {
    return NO;
    }
// a data address IS an i32 const
- (BOOL)hoistsGlobalAddr
    {
    return NO;
    }
// download size
- (BOOL)unrollsVariableTrip
    {
    return NO;
    }
// "Measure, don't assume" (§9): pointer-IV, IV-narrowing (narrow ops need
// masking), accumulator recursion — all OFF until measured under a real engine.
// The backend lowers every V* opcode to wasm SIMD (v128) — W4.
- (BOOL)vectorizesLoops
    {
    return YES;
    }
// Modest unroll caps, between the 6502's 4/8 and arm64's 32/64.
- (NSUInteger)unrollMaxTrip
    {
    return 8;
    }
- (NSUInteger)unrollMaxBodyInsns
    {
    return 24;
    }
- (NSUInteger)unrollFnInsnBudget
    {
    return 2048;
    }
- (BOOL)unrollAllowsMultipleCarriedValues
    {
    return YES;
    }
@end

@implementation XTIRX86_64TargetProfile

- (BOOL)inlinesAggregateParams
    {
    return YES;   // aggregates are ordinary addressable memory
    }

// x86-64 is a flat native target with a 32-bit-displacement stack frame and a
// register-homing allocator, so it relaxes almost every knob the 6502 keeps
// tight. SSE `sqrtsd` is the hardware sqrt. Varargs use the portable
// __xtc_va_buf pack buffer (NON-native): the xtc Stdio reads args via va_arg
// itself (never forwards to C vprintf), so the VaArgExpand pass lowering
// VaStart/VaArg → buffer loads/stores — which the backend already handles — is
// all that's needed; no System V register-save-area required.
- (BOOL)lowersSqrtToHardware
    {
    return YES;
    }
- (BOOL)usesNativeVarargs
    {
    return NO;
    }
- (BOOL)vectorizesLoops
    {
    return YES;
    }
// Loop transforms the reduction / min-max / count / widening-sum recognisers
// need to see the loop in canonical (rotated, if-converted) form.
- (BOOL)rotatesLoops
    {
    return YES;
    }
- (BOOL)ifConvertsPredicates
    {
    return YES;
    }
- (BOOL)hoistsLoopInvariants
    {
    return YES;
    }
- (BOOL)formsPointerInductionVars
    {
    return YES;
    }
- (BOOL)unrollsVariableTrip
    {
    return YES;
    }
- (BOOL)collapsesInvariantReductions
    {
    return YES;
    }
// Larger unrolls: no small-frame / slot-offset limit (slots are [rbp-imm32],
// effectively unbounded), so match arm64's caps and allow reduction-accumulator
// (multiple-carried) unrolls. No unrollMaxFrameValueIds gate needed.
- (NSUInteger)unrollMaxTrip
    {
    return 32;
    }
- (NSUInteger)unrollMaxBodyInsns
    {
    return 64;
    }
- (NSUInteger)unrollFnInsnBudget
    {
    return 8192;
    }
- (BOOL)unrollAllowsMultipleCarriedValues
    {
    return YES;
    }
// Pure CFG/SSA size/robustness wins (verified target-neutral for x86-64):
// redundant-init-guard elimination + hoist-to-entry, tail-recursion → loop
// (deep tail recursion otherwise overflows the native stack), and
// global-address hoist (the backend keys ElementAddr/FieldAddr strides off the
// base value's pointee type, so hoisting AddrOf @sym preserves strides).
- (BOOL)eliminatesRedundantInitGuards
    {
    return YES;
    }
- (BOOL)hoistsInitGuardsToEntry
    {
    return YES;
    }
- (BOOL)convertsTailRecursion
    {
    return YES;
    }
- (BOOL)hoistsGlobalAddr
    {
    return YES;
    }
// pow(x,2)→x*x: SSE mulsd is IEEE, matches the libm path (like the sqrt fold).
- (BOOL)foldsPowSquare
    {
    return YES;
    }
// Byte-fill loop → memset call (musl provides memset; backend lowers MemSet/
// MemCopy to System V call memset/memcpy).
- (BOOL)recognisesMemsetIdiom
    {
    return YES;
    }
@end
