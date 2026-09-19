#import "XTIROptPipeline.h"
#import "XTIR.h"
#import "XTIROptDeadFunctionElim.h"
#import "XTIROptVaArgExpand.h"
#import "XTIROptInline.h"
#import "XTIROptConstOperandFold.h"
#import "XTIROptStrengthReduce.h"
#import "XTIROptLoopUnroll.h"
#import "XTIROptLoopUnrollVarTrip.h"
#import "XTIROptIdiomMemset.h"
#import "XTIROptRedundantLoadCSE.h"
#import "XTIROptDeadCode.h"
#import "XTIROptStaticInitGuard.h"
#import "XTIROptPowSquare.h"
#import "XTIROptSqrtIntrinsic.h"
#import "XTIROptConstHoist.h"
#import "XTIROptLICM.h"
#import "XTIROptArcSelfRetain.h"
#import "XTIROptTailRecursion.h"
#import "XTIROptIfConvert.h"
#import "XTIROptJumpThread.h"
#import "XTIROptAggExpand.h"
#import "XTIROptMem2Reg.h"
#import "XTIROptBlockLayout.h"
#import "XTIROptLoopRotate.h"
#import "XTIROptVectorize.h"
#import "XTIROptPointerIV.h"
#import "XTIROptLoopReductionCollapse.h"
#import "XTIROptNarrow.h"
#import "XTIROptNarrowIV.h"
#import "XTIROptTargetProfile.h"

@implementation XTIROptPipeline
    {
    NSMutableArray<id<XTIROptPass>>* _passes;
    NSInteger _level;
    }

+ (instancetype)standardPipelineAtLevel:(NSInteger)level
    {
    return [self standardPipelineAtLevel:level
                                 profile:[XTIROptTargetProfile conservativeProfile]];
    }

+ (instancetype)standardPipelineAtLevel:(NSInteger)level
                                profile:(XTIROptTargetProfile*)profile
    {
    if (!profile)
        profile = [XTIROptTargetProfile conservativeProfile];
    XTIROptPipeline* p = [[XTIROptPipeline alloc] initAtLevel:level];
    // Default lowering for the abstract VaStart/VaArg ops → the __xtc_va_buf
    // pack buffer. Runs UNCONDITIONALLY (even at -O0): the backend has no case
    // for the abstract ops, so they must be gone. (A native-varargs backend
    // intercepts them before this; until then every target uses the buffer.)
    XTIROptVaArgExpand* vaExpand = [[XTIROptVaArgExpand alloc] init];
    vaExpand.profile = profile; // skips native-varargs targets (arm9)
    [p addPass:vaExpand];
    if (level >= 1)
        {
        [p addPass:[[XTIROptDeadFunctionElim alloc] init]];
        // Canonicalise a library sqrt call → the FSqrt op, so the backend
        // instruction-selects it (fsqrt/vsqrt) instead of name-matching the call.
        // Lives in Math$sqrt's body, so it converts before/through inlining; the
        // now-callerless _xm_sqrt[f] extern is then dropped by DFE.
        XTIROptSqrtIntrinsic* sqrtIn = [[XTIROptSqrtIntrinsic alloc] init];
        sqrtIn.profile = profile;
        [p addPass:sqrtIn];
        }
    if (level >= 2)
        {
        // Strength-reduce pow(x,2)→x*x before inlining (matches the library
        // pow wrapper call while it's still present); the now-dead wrapper +
        // libm pow are dropped by the DFE after inline.
        XTIROptPowSquare* powSq = [[XTIROptPowSquare alloc] init];
        powSq.profile = profile;
        [p addPass:powSq];
        [p addPass:[[XTIROptArcSelfRetain alloc] init]];
        // Inline small single-block leaves first, then re-run DFE to drop
        // callees that inlining left with no remaining callers; the
        // arithmetic/memory passes then clean up the spliced bodies (e.g.
        // CSE'ing the repeated AddrOf @__sdata_* a wrapper carried in).
        XTIROptInline* inl = [[XTIROptInline alloc] init];
        inl.profile = profile;
        [p addPass:inl];
        [p addPass:[[XTIROptDeadFunctionElim alloc] init]];
        // Demanded-width narrowing: recompute a wide arithmetic result at the
        // narrower width it is immediately truncated to (`u16 y = a*b` → 16-bit
        // multiply), so C-style integer promotion costs nothing where the result
        // is narrowed. Runs before the arithmetic passes; the DeadCode sweep
        // below removes the orphaned wide ops + their Ext feeders.
        [p addPass:[[XTIROptNarrow alloc] init]];
        // Convert self-recursion in tail position to a loop (profile-gated).
        // Runs after inlining (so leaves are folded and the self-call set is
        // settled) and before the loop unrollers / CSE / DCE, which then clean
        // up the loop body it produces.
        XTIROptTailRecursion* tailrec = [[XTIROptTailRecursion alloc] init];
        tailrec.profile = profile;
        [p addPass:tailrec];
        // If-convert short-circuit / predicate diamonds to branchless Selects
        // (profile-gated). Runs before the unrollers so a body it linearises is
        // simpler for them, and before CSE / const-fold, which then clean up the
        // straight-line code it produces.
        XTIROptIfConvert* ifconv = [[XTIROptIfConvert alloc] init];
        ifconv.profile = profile;
        [p addPass:ifconv];
        [p addPass:[[XTIROptJumpThread alloc] init]];
        [p addPass:[[XTIROptAggExpand alloc] init]];
        [p addPass:[[XTIROptMem2Reg alloc] init]];
        // Drop redundant static-init guards (profile-gated) before unrolling,
        // so the guard's load/compare/branch is gone from hot bodies.
        XTIROptStaticInitGuard* guards = [[XTIROptStaticInitGuard alloc] init];
        guards.profile = profile;
        [p addPass:guards];
        // Recognise byte-fill loops as memset BEFORE unrolling (else the fill
        // loop gets unrolled instead of collapsed to a call).
        XTIROptIdiomMemset* memset = [[XTIROptIdiomMemset alloc] init];
        memset.profile = profile;
        [p addPass:memset];
        // Drop dead code (incl. dead phis) before vectorising, so a nested
        // loop's inner counter carried into the outer header (dead) doesn't
        // make the inner iv look escaping and block vectorisation.
        [p addPass:[[XTIROptDeadCode alloc] init]];
        // Collapse an invariant reduction nest (outer rep loop whose only
        // carried value besides its IV is an accumulator fed by an inner
        // reduction over outer-invariant arrays) to `acc += T·delta`, computing
        // the inner delta once — clang's hoist. Profile-gated
        // (collapsesInvariantReductions — arm64). Runs after DCE (so dead outer
        // carries are gone) and before vectorise/unroll (so the single surviving
        // inner-loop copy still gets vectorised).
        XTIROptLoopReductionCollapse* redCollapse = [[XTIROptLoopReductionCollapse alloc] init];
        redCollapse.profile = profile;
        [p addPass:redCollapse];
        // CSE redundant loads/address arithmetic BEFORE vectorising, so a body
        // that reloads the same element (e.g. `c[i]=a[i]*b[i]+a[i]`) issues one
        // vector load, not two. (CSE also runs after, for the scalar paths.)
        [p addPass:[[XTIROptRedundantLoadCSE alloc] init]];
        // Auto-vectorise elementwise map loops to NEON SIMD (profile-gated),
        // BEFORE the unrollers (which would otherwise replicate the scalar body
        // and defeat recognition). The unrollers skip vector-op bodies.
        XTIROptVectorize* vectorize = [[XTIROptVectorize alloc] init];
        vectorize.profile = profile;
        [p addPass:vectorize];
        XTIROptLoopUnroll* unroll = [[XTIROptLoopUnroll alloc] init];
        unroll.profile = profile; // target-tuned caps / capabilities
        [p addPass:unroll];
        // Drop dead code (incl. dead phis) before the variable-trip unroller, so
        // a loop-carried value the lowering threads but never reads — e.g. a
        // nested loop's inner counter carried into the outer header — doesn't
        // pin its source "live" and block the unroller's no-escape check.
        [p addPass:[[XTIROptDeadCode alloc] init]];
        // Strength-reduce loop array addressing to advancing pointer phis BEFORE
        // the variable-trip unroller (profile-gated) — the unroller then threads
        // each pointer phi through the unrolled copies, so every copy loads from
        // its own advanced pointer (no per-copy address recompute at all).
        XTIROptPointerIV* ptriv = [[XTIROptPointerIV alloc] init];
        ptriv.profile = profile;
        [p addPass:ptriv];
        // Partial-unroll the remaining variable-trip loops (profile-gated),
        // threading any reduction/accumulator (and pointer IV) alongside the iv.
        XTIROptLoopUnrollVarTrip* unrollVT = [[XTIROptLoopUnrollVarTrip alloc] init];
        unrollVT.profile = profile;
        [p addPass:unrollVT];
        [p addPass:[[XTIROptStrengthReduce alloc] init]];
        [p addPass:[[XTIROptConstOperandFold alloc] init]];
        [p addPass:[[XTIROptRedundantLoadCSE alloc] init]];
        // Hoist loop-invariant address arithmetic / field loads to the preheader
        // (e.g. a container's reloaded backing-buffer pointer). Profile-gated.
        XTIROptLICM* licm = [[XTIROptLICM alloc] init];
        licm.profile = profile;
        [p addPass:licm];
        // Dedupe replicated float constants (unroll/inline copies) so each is
        // materialised once and the allocator homes it across the loop.
        XTIROptConstHoist* constHoist = [[XTIROptConstHoist alloc] init];
        constHoist.profile = profile; // enables global-addr hoist on arm64
        [p addPass:constHoist];
        // Rotate top-tested loops to bottom-tested (profile-gated), so the
        // back-edge is a single conditional branch. Runs after the unrollers
        // (which expect the canonical top-tested shape) and the arithmetic passes
        // (so the guard it duplicates is in final form).
        XTIROptLoopRotate* rotate = [[XTIROptLoopRotate alloc] init];
        rotate.profile = profile;
        [p addPass:rotate];
        // Narrow counted-loop induction variables to the smallest width holding
        // their range (profile-gated). Runs last, on the final loop shape, so a
        // 4-byte compare/increment becomes 1-byte on the 8-bit target; the DCE
        // below drops the now-dead wide bound cast/const.
        XTIROptNarrowIV* narrowIV = [[XTIROptNarrowIV alloc] init];
        narrowIV.profile = profile;
        [p addPass:narrowIV];
        // Final sweep: drop pure instructions orphaned by inlining and the
        // value-rewriting passes above (e.g. an inlined nullary call's
        // unused receiver AddrOf).
[p addPass:[[XTIROptDeadCode alloc] init]];
        // LAST: order the blocks so a conditional branch's expected successor
        // falls through. Nothing after this may reorder or add blocks, and
        // nothing before it is affected — the pass rewrites no instruction,
        // only the order fn.blocks holds them in.
        XTIROptBlockLayout* layout = [[XTIROptBlockLayout alloc] init];
        layout.profile = profile;
        [p addPass:layout];
        }
    return p;
    }

- (instancetype)initAtLevel:(NSInteger)level
    {
    self = [super init];
    if (self)
        {
        _passes = [NSMutableArray array];
        _level = level;
        }
    return self;
    }

- (void)addPass:(id<XTIROptPass>)pass
    {
    [_passes addObject:pass];
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    // NOTE: do NOT early-return at -O0. Passes with minOptLevel 0 are MANDATORY
    // LOWERING, not optimisations — chiefly VaArgExpand, which turns the abstract
    // VaStart/VaArg ops into __xtc_va_buf reads the backend can lower. Skipping it
    // at -O0 left every variadic callee (printf, …) reading unlowered ops → args
    // arrived as 0 (bug 014). The per-pass `minOptLevel > _level` filter below
    // still keeps the real optimisations (minOptLevel ≥ 1) off at -O0.
    // XTIR_OPT_STOP_AFTER=<pass name>: run the pipeline up to and including
    // that pass, then stop. It exists for the ported optimiser's differential
    // harness (selfhost/tools/opt-diff.sh): without it a pass can only be
    // compared once EVERY pass ahead of it in the pipeline is ported, which
    // makes a twenty-pass level all-or-nothing. Unset in every normal build.
    const char* stopAfter = getenv("XTIR_OPT_STOP_AFTER");
    for (id<XTIROptPass> pass in _passes)
        {
        if (pass.minOptLevel > _level)
            continue;
        NSUInteger fnBefore = mod.functions.count;
        NSUInteger symBefore = mod.symbols.count;
        NSMutableArray<NSString*>* errs = nil;
        if (![pass runOnModule:mod errors:&errs])
            {
            if (outErrors)
                *outErrors = errs;
            return NO;
            }
        if (stopAfter && [pass.passName isEqualToString:@(stopAfter)])
            return YES;
        if (_traceToStderr)
            {
            NSUInteger fnAfter = mod.functions.count;
            NSUInteger symAfter = mod.symbols.count;
            if (fnBefore != fnAfter || symBefore != symAfter)
                {
                fprintf(stderr,
                        "xcc: ir-opt pass '%s': functions %lu→%lu, symbols %lu→%lu\n",
                        pass.passName.UTF8String,
                        (unsigned long)fnBefore, (unsigned long)fnAfter,
                        (unsigned long)symBefore, (unsigned long)symAfter);
                }
            }
        }
    // Values that no surviving instruction defines are dropped. A pass that
    // deletes an instruction leaves its result registered — the function's
    // value table still holds it, nothing defines it, and the printer (which
    // emits instructions) never mentions it again.
    //
    // The slot-per-value back ends then reserve a frame slot for every
    // registered value, so every optimised function carried dead stack; and
    // the -O3 differentials compare a back end fed the IN-MEMORY module
    // against one fed the PRINTED IR, which has only the live values, so the
    // two saw different sets and disagreed about frames for no reason a reader
    // could see. private:docs/bugs/090.
    for (XTIRFunction* fn in mod.functions)
        [self pruneDeadValues:fn];
    return YES;
    }

/****************************************************************************\
|* Drop every value the function still has registered that nothing defines.
|*
|* "Defines" is wider than `insn.result`, and the first attempt at this got it
|* wrong in both directions it could:
|*
|*   * a MULTI-RESULT instruction (`%50:Agg, %51 = Load`) defines its memory
|*     token as `memoryResult`, which walking `result` alone never sees;
|*   * a FRAME-PINNED local is defined by the frame, not by any instruction —
|*     dropping one removed the whole pinned area, and on `_array_natural_cmp`
|*     that single 32-byte aggregate WAS the entire frame discrepancy.
|*
|* Parameters are defined by the call, so they are never pruned either.
|* @param fn  The function to prune.
\****************************************************************************/
- (void)pruneDeadValues:(XTIRFunction*)fn
    {
    NSMutableSet<NSNumber*>* live = [NSMutableSet set];
    for (NSUInteger i = 0; i < fn.paramTypes.count; i++)
        [live addObject:@(i)];
    for (XTIRPinnedLocal* p in fn.frameInfo.pinnedLocals)
        [live addObject:@(p.valueId)];
    for (XTIRBlock* b in fn.blocks)
        {
        for (XTIRInsn* p in b.phiNodes)
            {
            if (p.result)
                [live addObject:@(p.result.valueId)];
            if (p.memoryResult)
                [live addObject:@(p.memoryResult.valueId)];
            }
        for (XTIRInsn* i in b.instructions)
            {
            if (i.result)
                [live addObject:@(i.result.valueId)];
            if (i.memoryResult)
                [live addObject:@(i.memoryResult.valueId)];
            }
        if (b.terminator.result)
            [live addObject:@(b.terminator.result.valueId)];
        if (b.terminator.memoryResult)
            [live addObject:@(b.terminator.memoryResult.valueId)];
        }
    NSArray<NSNumber*>* ids = fn.values.allKeys;
    for (NSNumber* k in ids)
        if (![live containsObject:k])
            [fn.values removeObjectForKey:k];
    }

@end
