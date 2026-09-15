#import "XTIROptLoopReductionCollapse.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"

// ── Loop reduction-nest collapse ─────────────────────────────────────────────
//
// Pattern (matches the shape clang hoists — see reduce.xc / dot.xc):
//   for (rep = 0; rep < T; rep++)          // outer counted loop, const trip T
//       for (i = 0; i < N; i++) acc += g(i)  // inner reduction; g O-invariant
// The inner reduction adds a per-outer-iteration delta = Σ g(i) that does not
// depend on the outer accumulator or the outer induction variable, so it is the
// same on every outer iteration.
//
// TRANSFORM. Rather than clone/relocate the inner loop, we use the affine
// identity acc_T = init + T·(acc₁ − init): run the outer loop exactly ONCE
// (rewrite its induction compare so trip = 1, so acc₁ = init + Σδ) and rescale
// the outer loop's live-out accumulator to the closed form init + T·(acc₁−init)
// with three ops (Sub/Mul/Add) at the head of the exit block. Exact for `+`
// over 2's-complement integers (T·Σδ mod 2^w == T repeated adds). No block
// cloning, no CFG relocation, no memory-token surgery — only the loop bound
// changes and the post-loop accumulator uses are redirected. A safety check
// requires that the ONLY non-memory value defined inside the outer loop that is
// used outside it is the accumulator (so running the body once can't corrupt a
// leaked outer-IV value); the outer body must also write no memory (a store
// there — e.g. map.xc's inner map loop — needs the invariant inner-loop hoist
// first, a later increment).

// A discovered natural loop.
@interface XTLRCLoop : NSObject
@property(nonatomic) NSUInteger header;                     // block index
@property(nonatomic) NSUInteger latch;                      // block index (back-edge source)
@property(nonatomic) NSInteger preheader;                   // block index, or -1 if not unique
@property(nonatomic, strong) NSMutableSet<NSNumber*>* body; // block indices
@end
@implementation XTLRCLoop
@end

@implementation XTIROptLoopReductionCollapse

- (NSString*)passName
    {
    return @"loop-reduction-collapse";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

static BOOL lrcTrace(void)
    {
    static int v = -1;
    if (v < 0)
        v = getenv("XTC_LRC_TRACE") ? 1 : 0;
    return v == 1;
    }

// Resolve a const/immediate reached through ZExt/SExt/Trunc chains (mirrors the
// loop-unroller's resolveConst).
static BOOL resolveConst(NSDictionary<NSNumber*, XTIRInsn*>* defOf,
                         XTIROperand* op, int64_t* out)
    {
    if (op.kind == XTIROperandKindImmI)
        {
        if (out)
            *out = op.intValue;
        return YES;
        }
    if (op.kind != XTIROperandKindUse)
        return NO;
    XTIRValueId cur = op.valueId;
    for (int d = 0; d < 16; d++)
        {
        XTIRInsn* def = defOf[@(cur)];
        if (!def)
            return NO;
        if (def.opcode == XTIROpConst)
            return (def.operands.count >= 1 && def.operands[0].kind == XTIROperandKindImmI)
                       ? (out ? (*out = def.operands[0].intValue, YES) : YES)
                       : NO;
        if ((def.opcode == XTIROpZExt || def.opcode == XTIROpSExt || def.opcode == XTIROpTrunc || def.opcode == XTIROpBitcast) && def.operands.count >= 1 && def.operands[0].kind == XTIROperandKindUse)
            {
            // A bound wider than 16 bits reaches the ICmp via Bitcast (U32→I32),
            // not ZExt — e.g. REPS ≥ 65536. Follow it too.
            cur = def.operands[0].valueId;
            continue;
            }
        return NO;
        }
    return NO;
    }

// Exact iteration count of an ascending counted loop, in closed form (no
// simulation and no cap — unlike the unroller's computeTrip, the collapse wants
// large trips: the whole point is folding a big rep loop, and T·Σδ mod 2^w is
// exact for any T). Returns 0 if not a terminating ascending counted loop.
static NSUInteger computeTrip(int64_t init, int64_t step, int64_t bound,
                              XTIRICmpPredicate pred)
    {
    if (step <= 0)
        return 0;
    switch (pred)
        {
    case XTIRICmpSLT:
        if (bound <= init)
            return 0;
        return (NSUInteger)((bound - init + step - 1) / step);
    case XTIRICmpSLE:
        if (bound < init)
            return 0;
        return (NSUInteger)((bound - init) / step + 1);
    case XTIRICmpULT:
        {
        uint64_t ui = (uint64_t)init, ub = (uint64_t)bound, us = (uint64_t)step;
        if (ub <= ui)
            return 0;
        return (NSUInteger)((ub - ui + us - 1) / us);
        }
    case XTIRICmpULE:
        {
        uint64_t ui = (uint64_t)init, ub = (uint64_t)bound, us = (uint64_t)step;
        if (ub < ui)
            return 0;
        return (NSUInteger)((ub - ui) / us + 1);
        }
    default:
        return 0;
        }
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (!prof.collapsesInvariantReductions)
        return YES;
    // Fixpoint per function: hoisting an invariant inner loop out of a rep loop
    // (map.xc) leaves the rep loop store-free, which the collapse then folds on
    // the next round. Each transform invalidates the CFG/def analysis, so we
    // rebuild it each round. Capped as a backstop.
    for (XTIRFunction* fn in mod.functions)
        for (int round = 0; round < 16 && [self analyzeFunction:fn]; round++)
            {
            }
    return YES;
    }

- (BOOL)analyzeFunction:(XTIRFunction*)fn
    {
    NSArray<XTIRBlock*>* blocks = fn.blocks;
    NSUInteger nb = blocks.count;
    if (nb == 0)
        return NO;

    // defOf: instruction results; defPhi: phi results; defBlk: block of any def.
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defPhi = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSNumber*>* defBlk = [NSMutableDictionary dictionary];
    NSMutableArray<NSMutableArray<NSNumber*>*>* preds = [NSMutableArray array];
    NSMutableArray<NSMutableArray<NSNumber*>*>* succs = [NSMutableArray array];
    for (NSUInteger i = 0; i < nb; i++)
        {
        [preds addObject:[NSMutableArray array]];
        [succs addObject:[NSMutableArray array]];
        }
    for (NSUInteger bi = 0; bi < nb; bi++)
        {
        XTIRBlock* bb = blocks[bi];
        for (XTIRInsn* phi in bb.phiNodes)
            if (phi.result)
                {
                defPhi[@(phi.result.valueId)] = phi;
                defBlk[@(phi.result.valueId)] = @(bi);
                }
        for (XTIRInsn* insn in bb.instructions)
            {
            if (insn.result)
                {
                defOf[@(insn.result.valueId)] = insn;
                defBlk[@(insn.result.valueId)] = @(bi);
                }
            if (insn.memoryResult)
                defBlk[@(insn.memoryResult.valueId)] = @(bi);
            }
        XTIRInsn* t = bb.terminator;
        if (t)
            for (XTIROperand* o in t.operands)
                if (o.kind == XTIROperandKindBlock && o.blockRef)
                    {
                    NSUInteger ti = [blocks indexOfObjectIdenticalTo:o.blockRef];
                    if (ti != NSNotFound)
                        {
                        [succs[bi] addObject:@(ti)];
                        [preds[ti] addObject:@(bi)];
                        }
                    }
        }

    // Dominators (dom[n] = {n} ∪ ⋂ dom[p]), block 0 = entry.
    NSMutableArray<NSMutableIndexSet*>* dom = [NSMutableArray array];
    NSMutableIndexSet* universe = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, nb)];
    for (NSUInteger i = 0; i < nb; i++)
        [dom addObject:(i == 0 ? [NSMutableIndexSet indexSetWithIndex:0] : [universe mutableCopy])];
    BOOL domChanged = YES;
    while (domChanged)
        {
        domChanged = NO;
        for (NSUInteger n = 1; n < nb; n++)
            {
            NSMutableIndexSet* inter = nil;
            for (NSNumber* p in preds[n])
                {
                if (!inter)
                    inter = [dom[p.unsignedIntegerValue] mutableCopy];
                else
                    {
                    NSMutableIndexSet* keep = [inter mutableCopy];
                    [inter enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
                      (void)stop;
                      if (![dom[p.unsignedIntegerValue] containsIndex:idx])
                          [keep removeIndex:idx];
                    }];
                    inter = keep;
                    }
                }
            if (!inter)
                inter = [NSMutableIndexSet indexSet];
            [inter addIndex:n];
            if (![inter isEqualToIndexSet:dom[n]])
                {
                dom[n] = inter;
                domChanged = YES;
                }
            }
        }

    // Natural loops from back-edges (latch→header where header dominates latch).
    NSMutableArray<XTLRCLoop*>* loops = [NSMutableArray array];
    for (NSUInteger li = 0; li < nb; li++)
        for (NSNumber* hn in succs[li])
            {
            NSUInteger hi = hn.unsignedIntegerValue;
            if (![dom[li] containsIndex:hi])
                continue; // not a real back-edge
            XTLRCLoop* L = [XTLRCLoop new];
            L.header = hi;
            L.latch = li;
            L.body = [NSMutableSet setWithObject:@(hi)];
            NSMutableArray<NSNumber*>* wl = [NSMutableArray arrayWithObject:@(li)];
            while (wl.count)
                {
                NSNumber* n = wl.lastObject;
                [wl removeLastObject];
                if ([L.body containsObject:n])
                    continue;
                [L.body addObject:n];
                if (n.unsignedIntegerValue != hi)
                    for (NSNumber* p in preds[n.unsignedIntegerValue])
                        [wl addObject:p];
                }
            NSMutableArray<NSNumber*>* outside = [NSMutableArray array];
            for (NSNumber* p in preds[hi])
                if (![L.body containsObject:p])
                    [outside addObject:p];
            L.preheader = (outside.count == 1) ? (NSInteger)outside[0].unsignedIntegerValue : -1;
            [loops addObject:L];
            }

    // One transform per invocation (the mutation invalidates the analysis
    // above). Try the invariant inner-loop HOIST first — it lifts a store-loop
    // (map.xc's b[i]=…) out of the rep loop, after which the rep loop is
    // store-free and the COLLAPSE folds it on the next round.
    for (XTLRCLoop* O in loops)
        if ([self tryHoistInnerLoop:O
                              loops:loops
                                 fn:fn
                             blocks:blocks
                              preds:preds
                             defBlk:defBlk])
            return YES;
    for (XTLRCLoop* O in loops)
        if ([self tryRecognizeOuter:O
                              loops:loops
                                 fn:fn
                             blocks:blocks
                              defOf:defOf
                             defPhi:defPhi
                             defBlk:defBlk])
            return YES;
    return NO;
    }

// Does the def-cone of `startVid`, restricted to blocks in `region`, reach any
// value in `taboo`? Used to prove the inner reduction's per-step delta does not
// depend on the outer accumulator or the outer induction variable.
static BOOL defConeReaches(XTIRValueId startVid, NSSet<NSNumber*>* taboo,
                           NSSet<NSNumber*>* region,
                           NSDictionary<NSNumber*, XTIRInsn*>* defOf,
                           NSDictionary<NSNumber*, XTIRInsn*>* defPhi,
                           NSDictionary<NSNumber*, NSNumber*>* defBlk)
    {
    NSMutableSet<NSNumber*>* seen = [NSMutableSet set];
    NSMutableArray<NSNumber*>* wl = [NSMutableArray arrayWithObject:@(startVid)];
    while (wl.count)
        {
        NSNumber* v = wl.lastObject;
        [wl removeLastObject];
        if ([seen containsObject:v])
            continue;
        [seen addObject:v];
        if ([taboo containsObject:v])
            return YES;
        NSNumber* db = defBlk[v];
        if (!db || ![region containsObject:db])
            continue; // defined outside the region ⇒ invariant leaf
        XTIRInsn* d = defOf[v] ?: defPhi[v];
        if (!d)
            continue;
        for (XTIROperand* o in d.operands)
            if (o.kind == XTIROperandKindUse)
                [wl addObject:@(o.valueId)];
        }
    return NO;
    }

static BOOL insnWritesMemory(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpStore:
    case XTIROpStoreVolatile:
    case XTIROpCall:
    case XTIROpCallBanked:
    case XTIROpCallCloaked:
    case XTIROpMemSet:
    case XTIROpMemCopy:
    case XTIROpRetain:
    case XTIROpRelease:
    case XTIROpWeakRegister:
    case XTIROpWeakUnregister:
    case XTIROpVTblDispatch:
    case XTIROpProtoDispatch:
    case XTIROpAsm:
        return YES;
    default:
        return NO;
        }
    }

// The base symbol a memory address ultimately roots at — an `AddrOf @sym`,
// reached through any number of `ElementAddr` / `Bitcast` steps — or nil when
// it can't be determined (a pointer param, a loaded pointer, IntToPtr, a phi).
// Used to decide whether an inner loop READS and WRITES the same array, which
// would make running it once (the hoist) differ from running it T times.
static NSNumber* lrcAddrBaseSym(XTIROperand* addr,
                                NSDictionary<NSNumber*, XTIRInsn*>* defOf)
    {
    for (int guard = 0; guard < 64; guard++)
        {
        if (!addr || addr.kind != XTIROperandKindUse)
            return nil;
        XTIRInsn* d = defOf[@(addr.valueId)];
        if (!d || d.operands.count < 1)
            return nil;
        if (d.opcode == XTIROpAddrOf)
            {
            if (d.operands[0].kind == XTIROperandKindSym)
                return @(d.operands[0].symbolId);
            // Stack array/scalar: AddrOf takes a frame-slot VALUE id (a pinned
            // local), stable across the loop and distinct per local. Use it as
            // the base identity so two different locals (map.xc's a[] and b[])
            // are provably disjoint. Namespace it above the symbolId range so a
            // local slot and a global symbol can't alias by numeric coincidence.
            if (d.operands[0].kind == XTIROperandKindUse)
                return @((uint64_t)d.operands[0].valueId | 0x4000000000000000ULL);
            return nil;
            }
        if (d.opcode == XTIROpElementAddr || d.opcode == XTIROpBitcast)
            {
            addr = d.operands[0]; // step toward the base pointer
            continue;
            }
        return nil; // Load-of-ptr / IntToPtr / phi → opaque
        }
    return nil;
    }

// Rebuild `bb`'s terminator with every block operand equal to `oldT` retargeted
// to `newT` (terminators are immutable — rebuild + reset/set).
- (void)retargetTerminatorOf:(XTIRBlock*)bb from:(XTIRBlock*)oldT to:(XTIRBlock*)newT
    {
    XTIRInsn* t = bb.terminator;
    if (!t)
        return;
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:t.operands.count];
    for (XTIROperand* o in t.operands)
        [ops addObject:(o.kind == XTIROperandKindBlock && o.blockRef == oldT)
                           ? [XTIROperand blockWithRef:newT]
                           : o];
    XTIRInsn* repl = [[XTIRInsn alloc] initWithOpcode:t.opcode result:nil operands:ops dbgLoc:t.dbgLoc];
    [bb resetTerminator];
    [bb setTerminator:repl];
    }

// Relabel every phi in `bb`: an incoming (block == oldB) becomes (block == newB),
// keeping the paired value operand.
- (void)relabelPhisIn:(XTIRBlock*)bb from:(XTIRBlock*)oldB to:(XTIRBlock*)newB
    {
    for (NSUInteger phiIdx = 0; phiIdx < bb.phiNodes.count; phiIdx++)
        {
        XTIRInsn* phi = bb.phiNodes[phiIdx];
        NSMutableArray<XTIROperand*>* ops = [phi.operands mutableCopy];
        BOOL touched = NO;
        for (NSUInteger k = 0; k + 1 < ops.count; k += 2)
            if (ops[k].kind == XTIROperandKindBlock && ops[k].blockRef == oldB)
                {
                ops[k] = [XTIROperand blockWithRef:newB];
                touched = YES;
                }
        if (!touched)
            continue;
        XTIRInsn* repl = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                   result:phi.result
                                                 operands:ops
                                                   dbgLoc:phi.dbgLoc];
        repl.memoryResult = phi.memoryResult;
        bb.phiNodes[phiIdx] = repl;
        }
    }

// Hoist an invariant inner loop L out of outer loop O to run once before O.
// Requires the map.xc shape: O's header continues to L's preheader P_i (whose
// sole predecessor is the header), L has a single exit E_i, L (with its
// preheader) uses no value defined inside O's body, and O's body outside L
// writes no memory. The relocation is 3 edge redirects + 1 phi relabel — the
// glue blocks P_i and E_i are repurposed rather than moved.
- (BOOL)tryHoistInnerLoop:(XTLRCLoop*)O
                    loops:(NSArray<XTLRCLoop*>*)loops
                       fn:(XTIRFunction*)fn
                   blocks:(NSArray<XTIRBlock*>*)blocks
                    preds:(NSArray<NSMutableArray<NSNumber*>*>*)preds
                   defBlk:(NSDictionary<NSNumber*, NSNumber*>*)defBlk
    {
    if (O.preheader < 0)
        return NO;
    XTIRBlock *Ho = blocks[O.header], *Po = blocks[O.preheader];

    // O's continue-target (header successor inside the body) and exit target.
    NSInteger contIdx = -1;
    for (NSNumber* sn in [self succIdxOf:O.header blocks:blocks])
        {
        if ([O.body containsObject:sn])
            {
            if (contIdx < 0)
                contIdx = (NSInteger)sn.unsignedIntegerValue;
            else
                return NO;
            }
        }
    if (contIdx < 0)
        return NO;

    for (XTLRCLoop* L in loops)
        {
        if (L.preheader < 0 || L.header == O.header)
            continue;
        if (!([L.body isSubsetOfSet:O.body] && L.body.count < O.body.count))
            continue;
        if (L.preheader != contIdx)
            continue; // P_i must be O's continue-target
        if (preds[L.preheader].count != 1 || preds[L.preheader][0].unsignedIntegerValue != O.header)
            continue; // sole pred = Ho

        XTIRBlock *Pi = blocks[L.preheader], *Hi = blocks[L.header];

        // Single exit E_i of L (header successor outside L.body).
        NSInteger exitIdx = -1;
        for (NSNumber* sn in [self succIdxOf:L.header blocks:blocks])
            {
            if ([L.body containsObject:sn])
                continue;
            if (exitIdx < 0)
                exitIdx = (NSInteger)sn.unsignedIntegerValue;
            else
                {
                exitIdx = -1;
                break;
                }
            }
        if (exitIdx < 0)
            return NO;
        XTIRBlock* Ei = blocks[exitIdx];

        // The region that moves out (L's body + its preheader). It must not use
        // any value defined inside O's body but outside the region (⇒ no
        // dependence on O's carried acc/iv; its inputs are O-invariant).
        NSMutableSet<NSNumber*>* region = [L.body mutableCopy];
        [region addObject:@(L.preheader)];
        for (NSNumber* bn in region)
            {
            XTIRBlock* bb = blocks[bn.unsignedIntegerValue];
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
            [all addObjectsFromArray:bb.instructions];
            if (bb.terminator)
                [all addObject:bb.terminator];
            for (XTIRInsn* insn in all)
                for (XTIROperand* o in insn.operands)
                    {
                    if (o.kind != XTIROperandKindUse)
                        continue;
                    NSNumber* db = defBlk[@(o.valueId)];
                    if (db && [O.body containsObject:db] && ![region containsObject:db])
                        return NO;
                    }
            }

        // Every store in the outer loop must live inside L's actual loop body
        // (so L is O's only writer, and after the hoist O is store-free and the
        // collapse can fire). Checking O.body \ L.body also covers L's preheader
        // P_i, which moves out with L but must not carry a store of its own.
        for (NSNumber* bn in O.body)
            {
            if ([L.body containsObject:bn])
                continue;
            for (XTIRInsn* insn in blocks[bn.unsignedIntegerValue].instructions)
                if (insnWritesMemory(insn.opcode))
                    return NO;
            }

            // Idempotence: the hoist runs L exactly ONCE in place of O's T iterations,
            // so it only preserves the final memory state if re-executing L would
            // recompute the SAME values — i.e. L is a MAP, not a read-modify-write
            // ACCUMULATE. A store-loop with no loads recomputes the same values every
            // pass (idempotent). Once it also loads, the arrays it LOADS must be
            // disjoint from those it STORES (else a stored value depends on memory L
            // itself wrote on an earlier outer pass — `m[i] = m[i] + 5` run once gives
            // 5 where T passes give 5·T). Compare address base symbols; refuse on any
            // opaque base (can't prove disjoint) or any other memory-effecting op (a
            // call / memset / retain has side effects that don't survive re-timing).
            {
            NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
            for (XTIRBlock* bb in fn.blocks)
                for (XTIRInsn* ins in bb.instructions)
                    if (ins.result)
                        defOf[@(ins.result.valueId)] = ins;
            NSMutableSet<NSNumber*>* storeSyms = [NSMutableSet set];
            NSMutableSet<NSNumber*>* loadSyms = [NSMutableSet set];
            BOOL anyLoad = NO, baseOpaque = NO;
            for (NSNumber* bn in L.body)
                {
                for (XTIRInsn* insn in blocks[bn.unsignedIntegerValue].instructions)
                    {
                    switch (insn.opcode)
                        {
                    case XTIROpLoad:
                    case XTIROpLoadVolatile:
                    case XTIROpVLoad:
                        {
                        anyLoad = YES;
                        NSNumber* s = insn.operands.count >= 1
                                          ? lrcAddrBaseSym(insn.operands[0], defOf)
                                          : nil;
                        if (s)
                            [loadSyms addObject:s];
                        else
                            baseOpaque = YES;
                        break;
                        }
                    case XTIROpStore:
                    case XTIROpStoreVolatile:
                    case XTIROpVStore:
                        {
                        NSNumber* s = insn.operands.count >= 1
                                          ? lrcAddrBaseSym(insn.operands[0], defOf)
                                          : nil;
                        if (s)
                            [storeSyms addObject:s];
                        else
                            baseOpaque = YES;
                        break;
                        }
                    default:
                        if (insnWritesMemory(insn.opcode))
                            return NO; // side effect
                        }
                    }
                }
            if (anyLoad)
                {
                if (baseOpaque)
                    return NO; // can't prove load/store disjoint
                [storeSyms intersectSet:loadSyms];
                if (storeSyms.count > 0)
                    return NO; // an array is both read and written → RMW
                }
            }

        // ── Surgery ─────────────────────────────────────────────────────────
        // A dedicated exit block routes L → O's header, so the L-header→O-header
        // edge is NOT critical (L's header has two successors and O's header two
        // predecessors — a direct edge would misplace O's phi-resolution copies
        // and corrupt the accumulator seed). New block: single pred (L header),
        // single succ (O header).
        XTIRBlock* L1exit = [[XTIRBlock alloc] init];
        L1exit.name = [NSString stringWithFormat:@"%@_hoisted_exit", Hi.name ?: @"loop"];
        [L1exit setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                        result:nil
                                                      operands:@[ [XTIROperand blockWithRef:Ho] ]
                                                        dbgLoc:nil]];
        // Insert just after L's last body block so its array position matches its
        // control-flow position (the register allocators derive live-interval
        // positions from block array order — a block appended at the end but
        // executed mid-CFG scrambles liveness).
        NSUInteger insertAt = 0;
        for (NSNumber* bn in L.body)
            if (bn.unsignedIntegerValue + 1 > insertAt)
                insertAt = bn.unsignedIntegerValue + 1;
        [fn.blocks insertObject:L1exit atIndex:insertAt];

        [self retargetTerminatorOf:Po from:Ho to:Pi];     // (a) preheader now enters L first
        [self retargetTerminatorOf:Hi from:Ei to:L1exit]; // (b) L's exit → dedicated block → O header
        [self retargetTerminatorOf:Ho from:Pi to:Ei];     // (c) O's body now starts at E_i (the rest)
        [self relabelPhisIn:Ho from:Po to:L1exit];        // (d) O header phis: preheader-edge → new block

        if (lrcTrace())
            fprintf(stderr, "xcc: loop-reduction-collapse: hoisted invariant inner loop "
                            "(blocks %lu..) out of outer loop (header block %lu)\n",
                    (unsigned long)L.header, (unsigned long)O.header);
        return YES;
        }
    return NO;
    }

- (BOOL)tryRecognizeOuter:(XTLRCLoop*)O
                    loops:(NSArray<XTLRCLoop*>*)loops
                       fn:(XTIRFunction*)fn
                   blocks:(NSArray<XTIRBlock*>*)blocks
                    defOf:(NSDictionary<NSNumber*, XTIRInsn*>*)defOf
                   defPhi:(NSDictionary<NSNumber*, XTIRInsn*>*)defPhi
                   defBlk:(NSDictionary<NSNumber*, NSNumber*>*)defBlk
    {
    if (O.preheader < 0)
        return NO;
    XTIRBlock* H = blocks[O.header];

    // The outer body must write no memory (clean reduce/dot case; a store in the
    // outer body needs the invariant-inner-loop hoist first — a later increment).
    for (NSNumber* bn in O.body)
        for (XTIRInsn* insn in blocks[bn.unsignedIntegerValue].instructions)
            switch (insn.opcode)
                {
            case XTIROpStore:
            case XTIROpStoreVolatile:
            case XTIROpLoadVolatile:
            case XTIROpCall:
            case XTIROpCallBanked:
            case XTIROpCallCloaked:
            case XTIROpMemSet:
            case XTIROpMemCopy:
            case XTIROpRetain:
            case XTIROpRelease:
            case XTIROpWeakRegister:
            case XTIROpWeakUnregister:
            case XTIROpVTblDispatch:
            case XTIROpProtoDispatch:
            case XTIROpAsm:
                return NO;
            default:
                break;
                }

    // Classify the outer header phis: exactly one induction variable (counted,
    // const trip) + exactly one integer accumulator. Anything else ⇒ bail.
    XTIRInsn *ivPhi = nil, *accPhi = nil, *icmpInsn = nil;
    NSUInteger trip = 0;
    int64_t ivInit = 0, ivStep = 0;
    XTIRValueId accNextVid = 0, accSeedVid = 0;
    for (XTIRInsn* phi in H.phiNodes)
        {
        if (!phi.result)
            return NO;
        // Pull the preheader-incoming (seed) and latch-incoming (next).
        XTIRValueId seed = 0, next = 0;
        BOOL haveSeed = NO, haveNext = NO;
        for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
            {
            XTIROperand *bo = phi.operands[k], *vo = phi.operands[k + 1];
            if (bo.kind != XTIROperandKindBlock || vo.kind != XTIROperandKindUse)
                continue;
            NSUInteger predIdx = [blocks indexOfObjectIdenticalTo:bo.blockRef];
            if (predIdx == (NSUInteger)O.preheader)
                {
                seed = vo.valueId;
                haveSeed = YES;
                }
            else if (predIdx == O.latch)
                {
                next = vo.valueId;
                haveNext = YES;
                }
            }
        if (!haveSeed || !haveNext)
            return NO;

        // Induction variable: next = Add(phi, constStep), header compares it to a
        // const bound with an SLT/ULT-family predicate.
        XTIRInsn* nextDef = defOf[@(next)];
        if (nextDef && nextDef.opcode == XTIROpAdd && !ivPhi)
            {
            int64_t step = 0;
            BOOL isIV = NO;
            if (nextDef.operands.count == 2)
                {
                XTIROperand *a = nextDef.operands[0], *b = nextDef.operands[1];
                if (a.kind == XTIROperandKindUse && a.valueId == phi.result.valueId && resolveConst(defOf, b, &step))
                    isIV = YES;
                else if (b.kind == XTIROperandKindUse && b.valueId == phi.result.valueId && resolveConst(defOf, a, &step))
                    isIV = YES;
                }
            if (isIV)
                {
                // Find the header ICmp on this iv against a const bound.
                for (XTIRInsn* insn in H.instructions)
                    {
                    if (insn.opcode != XTIROpICmp || insn.operands.count < 2)
                        continue;
                    if (insn.operands[0].kind != XTIROperandKindUse || insn.operands[0].valueId != phi.result.valueId)
                        continue;
                    int64_t init = 0, bound = 0;
                    if (!resolveConst(defOf, [self seedOperandOf:phi predIdx:(NSUInteger)O.preheader blocks:blocks], &init))
                        continue;
                    if (!resolveConst(defOf, insn.operands[1], &bound))
                        continue;
                    NSUInteger t = computeTrip(init, step, bound, insn.predicate);
                    if (t > 0)
                        {
                        trip = t;
                        ivInit = init;
                        ivStep = step;
                        icmpInsn = insn;
                        }
                    }
                if (trip > 0)
                    {
                    ivPhi = phi;
                    continue;
                    }
                }
            }
        // Otherwise it must be the (single) accumulator; recorded, validated below.
        if (accPhi)
            return NO; // a second non-IV carried value ⇒ bail
        accPhi = phi;
        accNextVid = next;
        accSeedVid = seed;
        }
    if (!ivPhi || !accPhi || !icmpInsn || trip < 2)
        return NO;

    // The accumulator's latch-incoming must be an INNER reduction loop's
    // accumulator phi P_i, seeded by the outer accumulator, accumulating with +
    // a per-step delta that depends on neither the outer accumulator nor the
    // outer IV (so Σ delta is invariant across the outer loop).
    XTIRInsn* innerAcc = defPhi[@(accNextVid)];
    if (!innerAcc)
        return NO;
    NSNumber* innerHdrBlk = defBlk[@(accNextVid)];
    if (!innerHdrBlk)
        return NO;
    XTLRCLoop* L = nil;
    for (XTLRCLoop* cand in loops)
        if (cand.header == innerHdrBlk.unsignedIntegerValue && [cand.body isSubsetOfSet:O.body] && cand.body.count < O.body.count)
            {
            L = cand;
            break;
            }
    if (!L || L.preheader < 0)
        return NO;

    // P_i = [innerPre: seedVid, innerLatch: P_i ⊕ delta]. Seed must be the outer
    // accumulator; op must be Add; delta must avoid the taboo set.
    XTIRValueId innerSeed = 0, innerNext = 0;
    BOOL hs = NO, hn = NO;
    for (NSUInteger k = 0; k + 1 < innerAcc.operands.count; k += 2)
        {
        XTIROperand *bo = innerAcc.operands[k], *vo = innerAcc.operands[k + 1];
        if (bo.kind != XTIROperandKindBlock || vo.kind != XTIROperandKindUse)
            continue;
        NSUInteger predIdx = [blocks indexOfObjectIdenticalTo:bo.blockRef];
        if (predIdx == (NSUInteger)L.preheader)
            {
            innerSeed = vo.valueId;
            hs = YES;
            }
        else if (predIdx == L.latch)
            {
            innerNext = vo.valueId;
            hn = YES;
            }
        }
    if (!hs || !hn)
        return NO;
    if (innerSeed != accPhi.result.valueId)
        return NO; // inner reduction chains the outer acc

    XTIRInsn* innerNextDef = defOf[@(innerNext)];
    if (!innerNextDef || innerNextDef.opcode != XTIROpAdd || innerNextDef.operands.count != 2)
        return NO;
    XTIROperand *ia = innerNextDef.operands[0], *ib = innerNextDef.operands[1];
    XTIRValueId deltaVid;
    if (ia.kind == XTIROperandKindUse && ia.valueId == innerAcc.result.valueId && ib.kind == XTIROperandKindUse)
        deltaVid = ib.valueId;
    else if (ib.kind == XTIROperandKindUse && ib.valueId == innerAcc.result.valueId && ia.kind == XTIROperandKindUse)
        deltaVid = ia.valueId;
    else
        return NO;

    NSMutableSet<NSNumber*>* taboo = [NSMutableSet setWithObjects:
                                                       @(accPhi.result.valueId), @(ivPhi.result.valueId),
                                                       @(innerAcc.result.valueId), nil];
    if (defConeReaches(deltaVid, taboo, O.body, defOf, defPhi, defBlk))
        return NO;

    // ── Safety: the outer loop's iteration count must leak ONLY through the
    // accumulator. Any other value defined inside the outer body that is used
    // outside it (e.g. the outer IV read after the loop) would be miscompiled by
    // running the body once. Memory tokens are exempt (advisory, loose model).
    NSInteger exitIdx = -1;
    for (NSNumber* bn in O.body)
        {
        for (NSNumber* sn in [self succIdxOf:bn.unsignedIntegerValue blocks:blocks])
            {
            if ([O.body containsObject:sn])
                continue;
            if (exitIdx < 0)
                exitIdx = (NSInteger)sn.unsignedIntegerValue;
            else if (exitIdx != (NSInteger)sn.unsignedIntegerValue)
                return NO; // multiple exits
            }
        }
    if (exitIdx < 0)
        return NO;
    NSMutableArray<NSArray*>* accUseSites = [NSMutableArray array]; // (insn, opIndex) outside body
    for (NSUInteger bi = 0; bi < blocks.count; bi++)
        {
        if ([O.body containsObject:@(bi)])
            continue;
        XTIRBlock* bb = blocks[bi];
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            for (NSUInteger oi = 0; oi < insn.operands.count; oi++)
                {
                XTIROperand* op = insn.operands[oi];
                if (op.kind != XTIROperandKindUse)
                    continue;
                NSNumber* db = defBlk[@(op.valueId)];
                if (!db || ![O.body containsObject:db])
                    continue; // defined outside outer body
                XTIRValue* v = [fn valueForId:op.valueId];
                if (v && v.type.kind == XTIRTypeKindMemory)
                    continue; // token leak OK
                if (op.valueId != accPhi.result.valueId)
                    return NO; // a non-acc value leaks
                [accUseSites addObject:@[ insn, @(oi) ]];
                }
        }
    if (accUseSites.count == 0)
        return NO; // accumulator dead after the loop — nothing to do

    // ── Transform ────────────────────────────────────────────────────────────
    // Run the outer loop exactly ONCE (acc₁ = init + Σδ), then rescale its
    // live-out to the closed form init + T·(acc₁ − init) = init + T·Σδ. Exact
    // for `+` over 2's-complement integers.
    XTIRType* accTy = accPhi.result.type;

    // 1. Rewrite the outer IV's header compare so the loop runs once.
    int64_t onceBound = (icmpInsn.predicate == XTIRICmpSLE || icmpInsn.predicate == XTIRICmpULE)
                            ? ivInit
                            : ivInit + ivStep;
    NSMutableArray<XTIROperand*>* cmpOps = [icmpInsn.operands mutableCopy];
    cmpOps[1] = [XTIROperand immIWithType:cmpOps[1].kind == XTIROperandKindUse
                                              ? ([fn valueForId:cmpOps[1].valueId].type ?: accTy)
                                              : accTy
                                    value:onceBound];
    XTIRInsn* newCmp = [[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                 result:icmpInsn.result
                                               operands:cmpOps
                                              predicate:icmpInsn.predicate
                                                 dbgLoc:icmpInsn.dbgLoc];
    NSUInteger ci = [H.instructions indexOfObjectIdenticalTo:icmpInsn];
    if (ci == NSNotFound)
        return NO;
    H.instructions[ci] = newCmp;

    // 2. Materialise closed = init + T·(acc − init) at the head of the exit block.
    XTIRBlock* exitBB = blocks[exitIdx];
    XTIRInsn* (^mk)(XTIROpcode, NSArray<XTIROperand*>*) = ^XTIRInsn*(XTIROpcode op, NSArray<XTIROperand*>* ops) {
      XTIRValueId rid = [fn allocateValueId];
      XTIRValue* rv = [[XTIRValue alloc] initWithValueId:rid
                                                    type:accTy
                                                 defSite:[[XTIRDefSite alloc] initWithBlock:exitBB insnIndex:0]];
      [fn registerValue:rv];
      return [[XTIRInsn alloc] initWithOpcode:op result:rv operands:ops dbgLoc:nil];
    };
    XTIROperand* initOp = [XTIROperand useWithValueId:accSeedVid];
    XTIROperand* accOp = [XTIROperand useWithValueId:accPhi.result.valueId];
    XTIRInsn* subI = mk(XTIROpSub, @[ accOp, initOp ]); // acc − init
    XTIRInsn* mulI = mk(XTIROpMul, @[ [XTIROperand useWithValueId:subI.result.valueId],
                                      [XTIROperand immIWithType:accTy
                                                          value:(int64_t)trip] ]); // ·T
    XTIRInsn* addI = mk(XTIROpAdd, @[ initOp,
                                      [XTIROperand useWithValueId:mulI.result.valueId] ]); // init +
    [exitBB.instructions insertObject:subI atIndex:0];
    [exitBB.instructions insertObject:mulI atIndex:1];
    [exitBB.instructions insertObject:addI atIndex:2];

    // 3. Redirect the post-loop accumulator uses to the closed form.
    XTIRValueId closedVid = addI.result.valueId;
    for (NSArray* site in accUseSites)
        {
        XTIRInsn* insn = site[0];
        NSUInteger oi = ((NSNumber*)site[1]).unsignedIntegerValue;
        NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
        ops[oi] = [XTIROperand useWithValueId:closedVid];
        XTIRInsn* repl = insn.predicate
                             ? [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                                         result:insn.result
                                                       operands:ops
                                                      predicate:insn.predicate
                                                         dbgLoc:insn.dbgLoc]
                             : [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                                         result:insn.result
                                                       operands:ops
                                                         dbgLoc:insn.dbgLoc];
        repl.memoryResult = insn.memoryResult;
        [self replaceInsn:insn with:repl blocks:blocks]; // phi / instructions / terminator
        }

    if (lrcTrace())
        fprintf(stderr,
                "xcc: loop-reduction-collapse: collapsed '%s' — outer trip %lu → 1, "
                "acc v%llu rescaled ×%lu (delta v%llu)\n",
                fn.name.UTF8String, (unsigned long)trip,
                (unsigned long long)accPhi.result.valueId, (unsigned long)trip,
                (unsigned long long)deltaVid);
    return YES;
    }

// Successor block indices of block `bi`.
- (NSArray<NSNumber*>*)succIdxOf:(NSUInteger)bi blocks:(NSArray<XTIRBlock*>*)blocks
    {
    NSMutableArray<NSNumber*>* s = [NSMutableArray array];
    XTIRInsn* t = blocks[bi].terminator;
    if (t)
        for (XTIROperand* o in t.operands)
            if (o.kind == XTIROperandKindBlock && o.blockRef)
                {
                NSUInteger si = [blocks indexOfObjectIdenticalTo:o.blockRef];
                if (si != NSNotFound)
                    [s addObject:@(si)];
                }
    return s;
    }

- (void)replaceInsn:(XTIRInsn*)insn with:(XTIRInsn*)repl blocks:(NSArray<XTIRBlock*>*)blocks
    {
    for (XTIRBlock* bb in blocks)
        {
        NSUInteger phiIdx = [bb.phiNodes indexOfObjectIdenticalTo:insn];
        if (phiIdx != NSNotFound)
            {
            bb.phiNodes[phiIdx] = repl;
            return;
            }
        NSUInteger insnIdx = [bb.instructions indexOfObjectIdenticalTo:insn];
        if (insnIdx != NSNotFound)
            {
            bb.instructions[insnIdx] = repl;
            return;
            }
        if (bb.terminator == insn)
            {
            [bb resetTerminator];
            [bb setTerminator:repl];
            return;
            }
        }
    }

// The preheader-incoming operand of `phi` (its seed), for resolveConst.
- (XTIROperand*)seedOperandOf:(XTIRInsn*)phi predIdx:(NSUInteger)pre
                       blocks:(NSArray<XTIRBlock*>*)blocks
    {
    for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
        {
        XTIROperand *bo = phi.operands[k], *vo = phi.operands[k + 1];
        if (bo.kind != XTIROperandKindBlock || vo.kind != XTIROperandKindUse)
            continue;
        if ([blocks indexOfObjectIdenticalTo:bo.blockRef] == pre)
            return vo;
        }
    return nil;
    }

@end
