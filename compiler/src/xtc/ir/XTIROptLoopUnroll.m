#import "XTIROptLoopUnroll.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIROptTargetProfile.h"

// A value carried across iterations besides the induction variable — an
// accumulator / reduction header phi. `seedOp` is its value from the
// preheader edge, `nextOp` the value the body feeds back. Both are SSA Uses
// (the lowering never threads an immediate through a phi).
@interface XTCarried : NSObject
@property(nonatomic) XTIRValueId phiId; // the header phi's result id
@property(nonatomic) XTIROperand* seedOp;
@property(nonatomic) XTIROperand* nextOp;
@end
@implementation XTCarried
@end

// A recognised unrollable loop.
@interface XTUnrollCand : NSObject
@property(nonatomic) XTIRBlock* header;
@property(nonatomic) XTIRBlock* body; // also the latch
@property(nonatomic) XTIRBlock* exit;
@property(nonatomic) XTIRBlock* preheader;
@property(nonatomic) XTIRInsn* phi; // the induction phi (in header)
@property(nonatomic) XTIRType* ivType;
@property(nonatomic) int64_t startVal;
@property(nonatomic) int64_t step;
@property(nonatomic) NSUInteger trip;
@property(nonatomic) NSArray<XTCarried*>* carried; // accumulator phis
@end
@implementation XTUnrollCand
@end

@implementation XTIROptLoopUnroll

- (NSString*)passName
    {
    return @"loop-unroll";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn];
    return YES;
    }

// ── Helpers ────────────────────────────────────────────────────────────

// Resolve an operand to a compile-time int, walking ZExt/SExt/Trunc of a
// Const (the widened-literal form) or a direct ImmI. Returns YES on success.
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
            {
            if (def.operands.count >= 1 && def.operands[0].kind == XTIROperandKindImmI)
                {
                if (out)
                    *out = def.operands[0].intValue;
                return YES;
                }
            return NO;
            }
        if ((def.opcode == XTIROpZExt || def.opcode == XTIROpSExt || def.opcode == XTIROpTrunc) && def.operands.count >= 1 && def.operands[0].kind == XTIROperandKindUse)
            {
            cur = def.operands[0].valueId;
            continue;
            }
        return NO;
        }
    return NO;
    }

// Simulate the loop to a trip count, capped at `maxTrip`. Returns 0 if not a
// terminating counted loop within the cap.
static NSUInteger computeTrip(int64_t init, int64_t step, int64_t bound,
                              XTIRICmpPredicate pred, NSUInteger maxTrip)
    {
    if (step <= 0)
        return 0; // only ascending counters
    int64_t i = init;
    NSUInteger trip = 0;
    for (NSUInteger n = 0; n <= maxTrip; n++)
        {
        BOOL cont;
        switch (pred)
            {
        case XTIRICmpULT:
            cont = (uint64_t)i < (uint64_t)bound;
            break;
        case XTIRICmpSLT:
            cont = i < bound;
            break;
        case XTIRICmpULE:
            cont = (uint64_t)i <= (uint64_t)bound;
            break;
        case XTIRICmpSLE:
            cont = i <= bound;
            break;
        default:
            return 0; // unsupported predicate
            }
        if (!cont)
            break;
        trip++;
        i += step;
        }
    if (trip == 0 || trip > maxTrip)
        return 0;
    return trip;
    }

// Block successors via terminator block operands.
static NSArray<XTIRBlock*>* successors(XTIRBlock* b)
    {
    NSMutableArray<XTIRBlock*>* out = [NSMutableArray array];
    for (XTIROperand* op in b.terminator.operands)
        if (op.kind == XTIROperandKindBlock && op.blockRef)
            [out addObject:op.blockRef];
    return out;
    }

static BOOL isCallOpcode(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpCall:
    case XTIROpCallBanked:
    case XTIROpCallCloaked:
    case XTIROpCallIndirect:
    case XTIROpVTblDispatch:
    case XTIROpProtoDispatch:
        return YES;
    default:
        return NO;
        }
    }

// Body op that makes unrolling unsafe. Plain scalar Load/Store are always
// fine (the backend emits in program order). Calls are allowed only when the
// target opts in — each copy re-issues the call, which is exactly the trip
// executions. Every other memory/opaque op (MemCopy/Set, Retain/Release,
// Weak*, Asm, aggregate, volatile) stays forbidden: replicating those is
// either unsound (refcount ops) or pointless.
static BOOL bodyOpForbidden(XTIROpcode op, BOOL allowCalls)
    {
    switch (op)
        {
    case XTIROpLoad:
    case XTIROpStore:
        return NO;
    default:
        if (isCallOpcode(op))
            return !allowCalls;
        return XTIROpcodeTouchesMemory(op);
        }
    }

// For header phi `phi`, split its incomings into (preheader init, body next),
// given the body block B. Returns NO if the phi isn't the 2-incoming
// (preheader, body) shape with both values being SSA Uses.
static BOOL splitPhi(XTIRInsn* phi, XTIRBlock* B,
                     XTIRBlock** outP, XTIROperand** outInit, XTIROperand** outNext)
    {
    if (phi.operands.count != 4)
        return NO;
    XTIRBlock *blk0 = phi.operands[0].blockRef, *blk1 = phi.operands[2].blockRef;
    XTIROperand *val0 = phi.operands[1], *val1 = phi.operands[3];
    if (blk1 == B && blk0 != B)
        {
        *outP = blk0;
        *outInit = val0;
        *outNext = val1;
        }
    else if (blk0 == B && blk1 != B)
        {
        *outP = blk1;
        *outInit = val1;
        *outNext = val0;
        }
    else
        return NO;
    return YES;
    }

// Recognise the unrollable loops in the CURRENT CFG. Re-run after each
// unroll rather than snapshotting once: unrolling one loop rewrites uses
// (escape remap) in sibling/outer loops, so a previously-captured operand
// (e.g. an accumulator a nested loop feeds a sibling) would otherwise go
// stale and the clone would reference a deleted value.
- (NSArray<XTUnrollCand*>*)candidatesIn:(XTIRFunction*)fn
                                profile:(XTIROptTargetProfile*)prof
    {
    NSUInteger maxTrip = prof.unrollMaxTrip;
    NSUInteger maxBody = prof.unrollMaxBodyInsns;
    BOOL allowMulti = prof.unrollAllowsMultipleCarriedValues;
    BOOL allowCalls = prof.unrollAllowsCallsInBody;

    // `for (...) : unroll` raises the BUDGETS for the loops that asked, and
    // nothing else. The profile's maxTrip/maxBodyInsns are a judgement about
    // when unrolling PAYS — that judgement is exactly what the annotation
    // overrides, because the author knows something the heuristic does not.
    //
    // Every other gate below stays: multiple carried phis, vector phis, the
    // single-predecessor body shape, forbidden opcodes. Those are CORRECTNESS
    // limits, not budget ones — a loop the unroller cannot transform safely is
    // not made safe by being asked twice.
    NSUInteger forcedTrip = maxTrip > 64 ? maxTrip : 64;
    NSUInteger forcedBody = maxBody > 64 ? maxBody : 64;

    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* phi in bb.phiNodes)
            if (phi.result)
                defOf[@(phi.result.valueId)] = phi;
        for (XTIRInsn* insn in bb.instructions)
            if (insn.result)
                defOf[@(insn.result.valueId)] = insn;
        }

    // Predecessor sets (block → its predecessors).
    NSMapTable<XTIRBlock*, NSMutableSet<XTIRBlock*>*>* preds =
        [NSMapTable strongToStrongObjectsMapTable];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRBlock* s in successors(bb))
            {
            NSMutableSet* set = [preds objectForKey:s];
            if (!set)
                {
                set = [NSMutableSet set];
                [preds setObject:set forKey:s];
                }
            [set addObject:bb];
            }

    // ── Recognise candidates (over a snapshot; loops are independent) ──
    NSMutableArray<XTUnrollCand*>* cands = [NSMutableArray array];
    for (XTIRBlock* H in [fn.blocks copy])
        {
        if (H.phiNodes.count < 1)
            continue;
        if (H.phiNodes.count > 1 && !allowMulti)
            continue; // multi-carry gate
        // Skip already-vectorised reduction loops (vector accumulator phi):
        // unrolling would clone the vector phi, which the backend's in-place
        // accumulate coalescing can't represent.
        BOOL hasVecPhi = NO;
        for (XTIRInsn* p in H.phiNodes)
            if (p.result && p.result.type.kind == XTIRTypeKindVec)
                {
                hasVecPhi = YES;
                break;
                }
        if (hasVecPhi)
            continue;

        // Header instructions must be only const/widen + exactly one ICmp.
        XTIRInsn* icmp = nil;
        BOOL headerClean = YES;
        for (XTIRInsn* insn in H.instructions)
            {
            switch (insn.opcode)
                {
            case XTIROpConst:
            case XTIROpZExt:
            case XTIROpSExt:
            case XTIROpTrunc:
                break;
            case XTIROpICmp:
                if (icmp)
                    headerClean = NO;
                else
                    icmp = insn;
                break;
            default:
                headerClean = NO;
                break;
                }
            if (!headerClean)
                break;
            }
        if (!headerClean || !icmp || !icmp.result)
            continue;

        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse || term.operands[0].valueId != icmp.result.valueId)
            continue;
        if (term.operands[1].kind != XTIROperandKindBlock || term.operands[2].kind != XTIROperandKindBlock)
            continue;
        XTIRBlock* tT = term.operands[1].blockRef;
        XTIRBlock* tF = term.operands[2].blockRef;

        // The body/latch is whichever target branches back to H; the other
        // is the exit. Require the back-edge target to do so unconditionally.
        XTIRBlock *B = nil, *E = nil;
        if (tT && tT.terminator && tT.terminator.opcode == XTIROpBranch && successors(tT).count == 1 && successors(tT)[0] == H)
            {
            B = tT;
            E = tF;
            }
        else if (tF && tF.terminator && tF.terminator.opcode == XTIROpBranch && successors(tF).count == 1 && successors(tF)[0] == H)
            {
            B = tF;
            E = tT;
            }
        if (!B || !E || B == H || E == H || B == E)
            continue;

        // Body must be a single straight-line block whose only pred is H.
        NSSet* bPreds = [preds objectForKey:B];
        if (bPreds.count != 1 || ![bPreds containsObject:H])
            continue;
        if (B.phiNodes.count != 0)
            continue;
        if (E.phiNodes.count != 0)
            continue; // no exit phi to rewire
        BOOL forced = H.name && [fn.forcedUnrollHeaders containsObject:H.name];
        NSUInteger bodyCap = forced ? forcedBody : maxBody;
        if (B.instructions.count == 0 || B.instructions.count > bodyCap)
            continue;
        BOOL bodyOK = YES;
        for (XTIRInsn* insn in B.instructions)
            if (bodyOpForbidden(insn.opcode, allowCalls))
                {
                bodyOK = NO;
                break;
                }
        if (!bodyOK)
            continue;

        // The induction phi is the one whose result the ICmp tests.
        if (icmp.operands.count < 2 || icmp.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRValueId ivId = icmp.operands[0].valueId;
        XTIRInsn* ivPhi = nil;
        for (XTIRInsn* p in H.phiNodes)
            if (p.result && p.result.valueId == ivId)
                {
                ivPhi = p;
                break;
                }
        if (!ivPhi || ivPhi.memoryResult)
            continue;

        // iv incomings: init (preheader, const) + next = `Add iv, c`.
        XTIRBlock* P = nil;
        XTIROperand *seedOp = nil, *nextOp = nil;
        if (!splitPhi(ivPhi, B, &P, &seedOp, &nextOp) || !P.terminator)
            continue;
        int64_t initV;
        if (!resolveConst(defOf, seedOp, &initV))
            continue;
        if (nextOp.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* nextDef = defOf[@(nextOp.valueId)];
        if (!nextDef || nextDef.opcode != XTIROpAdd || nextDef.operands.count < 2)
            continue;
        int64_t stepV;
        XTIROperand *a = nextDef.operands[0], *b = nextDef.operands[1];
        /* ok */
        if (a.kind == XTIROperandKindUse && a.valueId == ivId && resolveConst(defOf, b, &stepV))
            {
            }
        /* ok */
        else if (b.kind == XTIROperandKindUse && b.valueId == ivId && resolveConst(defOf, a, &stepV))
            {
            }
        else
            continue;
        int64_t boundV;
        if (!resolveConst(defOf, icmp.operands[1], &boundV))
            continue;

        NSUInteger trip = computeTrip(initV, stepV, boundV,
                                      (XTIRICmpPredicate)icmp.predicate,
                                      forced ? forcedTrip : maxTrip);
        if (trip < 2)
            continue; // trip 0/1 not worth the machinery

        // The unrolled body is one block and everything in it is live there.
        // Past a point that costs more in spills than the removed branches
        // save — see the note on unrollMaxTotalInsns.
        NSUInteger totalCap = prof.unrollMaxTotalInsns;
        if (!forced && totalCap > 0 && trip * B.instructions.count > totalCap)
            continue;

        // Every other header phi is an accumulator carried across iterations.
        // Each must have the (preheader init, body next) shape with both
        // values being SSA Uses (so the per-copy threading is value-id only).
        NSMutableArray<XTCarried*>* carried = [NSMutableArray array];
        BOOL carriedOK = YES;
        for (XTIRInsn* p in H.phiNodes)
            {
            if (p == ivPhi)
                continue;
            if (!p.result || p.memoryResult)
                {
                carriedOK = NO;
                break;
                }
            XTIRBlock* cp = nil;
            XTIROperand *ci = nil, *cn = nil;
            if (!splitPhi(p, B, &cp, &ci, &cn) || cp != P)
                {
                carriedOK = NO;
                break;
                }
            if (ci.kind != XTIROperandKindUse || cn.kind != XTIROperandKindUse)
                {
                carriedOK = NO;
                break;
                }
            XTCarried* c = [XTCarried new];
            c.phiId = p.result.valueId;
            c.seedOp = ci;
            c.nextOp = cn;
            [carried addObject:c];
            }
        if (!carriedOK)
            continue;

        // The iv must not be used outside the header/body (we'd otherwise
        // need to materialise its final value). Accumulators MAY escape — we
        // remap their uses to the final copy below.
        BOOL ivEscapes = NO;
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            for (XTIRInsn* insn in [XTIROptLoopUnroll allInsns:bb])
                {
                for (XTIROperand* op in insn.operands)
                    if (op.kind == XTIROperandKindUse && op.valueId == ivId)
                        {
                        ivEscapes = YES;
                        break;
                        }
                if (ivEscapes)
                    break;
                }
            if (ivEscapes)
                break;
            }
        if (ivEscapes)
            continue;

        XTUnrollCand* c = [XTUnrollCand new];
        c.header = H;
        c.body = B;
        c.exit = E;
        c.preheader = P;
        c.phi = ivPhi;
        c.ivType = ivPhi.result.type;
        c.startVal = initV;
        c.step = stepV;
        c.trip = trip;
        c.carried = carried;
        [cands addObject:c];
        }
    return cands;
    }

static BOOL bodyHasCall(XTIRBlock* B)
    {
    for (XTIRInsn* insn in B.instructions)
        if (isCallOpcode(insn.opcode))
            return YES;
    return NO;
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    NSUInteger fnBudget = prof.unrollFnInsnBudget;
    NSUInteger frameIdCeil = prof.unrollMaxFrameValueIds;

    // Unroll one loop at a time, re-recognising after each (the apply rewrites
    // the IR, so a fresh scan avoids stale captured operands). Each unroll
    // removes a loop, so the candidate set shrinks — the guard caps any
    // pathological case. A loop that would bust the budget is left alone.
    for (NSUInteger iter = 0; iter < 4096; iter++)
        {
        NSArray<XTUnrollCand*>* cands = [self candidatesIn:fn profile:prof];
        if (cands.count == 0)
            break;
        NSUInteger fnInsns = 0;
        for (XTIRBlock* bb in fn.blocks)
            fnInsns += bb.phiNodes.count + bb.instructions.count + (bb.terminator ? 1 : 0);
        XTUnrollCand* chosen = nil;
        for (XTUnrollCand* c in cands)
            {
            NSUInteger added = (c.trip - 1) * (c.body.instructions.count + 1);
            if (fnInsns + added > fnBudget)
                continue;
            // Call bodies grow the value count (each clone allocates fresh
            // result/memResult ids), which sizes the arm64 stack frame; cap it
            // so every value slot stays addressable (str/ldr w,[sp,#≤16380]).
            //
            // Counted over the values the function actually HOLDS, not over
            // `nextValueId`. That counter is monotonic — it includes every id
            // any earlier pass allocated and then discarded — so the same
            // source could unroll or not depending on how many ids the passes
            // ahead of this one happened to burn. What the cap is really asking
            // is how many slots the frame needs, and that is the live count.
            if (bodyHasCall(c.body))
                {
                NSUInteger addedIds =
                    c.trip * (2 * c.body.instructions.count + 1) + 1;
                NSUInteger liveIds = fn.paramTypes.count + fn.frameInfo.pinnedLocals.count;
                for (XTIRBlock* bb in fn.blocks)
                    for (XTIRInsn* insn in [XTIROptLoopUnroll allInsns:bb])
                        {
                        if (insn.result)
                            liveIds++;
                        if (insn.memoryResult)
                            liveIds++;
                        }
                if (liveIds + addedIds > frameIdCeil)
                    continue;
                }
            chosen = c;
            break;
            }
        if (!chosen)
            {
            fprintf(stderr,
                    "xcc: loop-unroll: not unrolling a %lu-trip loop in '%s' "
                    "(would risk code size); left as a loop\n",
                    (unsigned long)cands.firstObject.trip, fn.name.UTF8String);
            break;
            }
        [self unroll:chosen inFunction:fn];
        }
    }

+ (NSArray<XTIRInsn*>*)allInsns:(XTIRBlock*)b
    {
    NSMutableArray<XTIRInsn*>* a = [NSMutableArray array];
    [a addObjectsFromArray:b.phiNodes];
    [a addObjectsFromArray:b.instructions];
    if (b.terminator)
        [a addObject:b.terminator];
    return a;
    }

// Remap a Use operand through `map` (oldId → newId); other kinds unchanged.
static XTIROperand* remapOp(XTIROperand* op, NSDictionary<NSNumber*, NSNumber*>* map)
    {
    if (op.kind != XTIROperandKindUse)
        return op;
    NSNumber* n = map[@(op.valueId)];
    if (!n)
        return op;
    return [XTIROperand useWithValueId:(XTIRValueId)n.unsignedLongLongValue];
    }

- (void)unroll:(XTUnrollCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock *H = c.header, *B = c.body, *E = c.exit, *P = c.preheader;
    XTIRValueId ivId = c.phi.result.valueId;
    XTIRType* memTy = [XTIRType memoryType];

    // ── Memory-SSA threading for call-bearing bodies ─────────────────
    // A body with a CALL threads memory through an opaque callee. Synthesise a
    // transient header memory phi (registered as a carried value) so the cloned
    // copies thread the memory token copy-to-copy. The phi is spliced out with
    // the loop, so it never reaches the verifier / CSE / backend. Plain
    // load/store bodies keep the original no-phi path (already correct).
    BOOL bodyHasCall = NO;
    for (XTIRInsn* insn in B.instructions)
        if (isCallOpcode(insn.opcode))
            {
            bodyHasCall = YES;
            break;
            }
    if (bodyHasCall)
        {
        XTIRInsn* firstMemInsn = nil;
        for (XTIRInsn* insn in B.instructions)
            if (XTIROpcodeTouchesMemory(insn.opcode))
                {
                firstMemInsn = insn;
                break;
                }
        XTIRValueId tin = 0;
        BOOL haveTin = NO;
        for (XTIROperand* op in firstMemInsn.operands)
            {
            if (op.kind != XTIROperandKindUse)
                continue;
            XTIRValue* v = [fn valueForId:op.valueId];
            if (v && v.type.kind == XTIRTypeKindMemory)
                {
                tin = op.valueId;
                haveTin = YES;
                break;
                }
            }
        XTIRValueId tlast = 0;
        BOOL haveTlast = NO;
        for (XTIRInsn* insn in B.instructions)
            if (insn.memoryResult)
                {
                tlast = insn.memoryResult.valueId;
                haveTlast = YES;
                }
        if (haveTin && haveTlast)
            {
            XTIRValueId memPhiId = [fn allocateValueId];
            XTIRValue* memPhiVal = [[XTIRValue alloc] initWithValueId:memPhiId
                                                                 type:memTy
                                                              defSite:[[XTIRDefSite alloc] initWithBlock:H insnIndex:0]];
            [fn registerValue:memPhiVal];
            NSUInteger pIdx = [fn.blocks indexOfObjectIdenticalTo:P];
            NSUInteger bIdx = [fn.blocks indexOfObjectIdenticalTo:B];
            NSArray<XTIROperand*>* phiOps = (pIdx <= bIdx)
                                                ? @[ [XTIROperand blockWithRef:P], [XTIROperand useWithValueId:tin],
                                                     [XTIROperand blockWithRef:B], [XTIROperand useWithValueId:tlast] ]
                                                : @[ [XTIROperand blockWithRef:B], [XTIROperand useWithValueId:tlast],
                                                     [XTIROperand blockWithRef:P], [XTIROperand useWithValueId:tin] ];
            [H.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                            result:memPhiVal
                                                          operands:phiOps
                                                            dbgLoc:nil]];
            NSUInteger fmi = [B.instructions indexOfObjectIdenticalTo:firstMemInsn];
            NSDictionary<NSNumber*, NSNumber*>* tinMap = @{@(tin) : @(memPhiId)};
            NSMutableArray<XTIROperand*>* fmOps =
                [NSMutableArray arrayWithCapacity:firstMemInsn.operands.count];
            for (XTIROperand* op in firstMemInsn.operands)
                [fmOps addObject:remapOp(op, tinMap)];
            XTIRInsn* fmRebuilt;
            if (firstMemInsn.callConv)
                fmRebuilt = [[XTIRInsn alloc] initWithOpcode:firstMemInsn.opcode
                                                      result:firstMemInsn.result
                                                    operands:fmOps
                                                    callConv:firstMemInsn.callConv
                                                      dbgLoc:firstMemInsn.dbgLoc];
            else
                fmRebuilt = [[XTIRInsn alloc] initWithOpcode:firstMemInsn.opcode
                                                      result:firstMemInsn.result
                                                    operands:fmOps
                                                      dbgLoc:firstMemInsn.dbgLoc];
            fmRebuilt.memoryResult = firstMemInsn.memoryResult;
            B.instructions[fmi] = fmRebuilt;
            XTCarried* memCarried = [XTCarried new];
            memCarried.phiId = memPhiId;
            memCarried.seedOp = [XTIROperand useWithValueId:tin];
            memCarried.nextOp = [XTIROperand useWithValueId:tlast];
            c.carried = [c.carried arrayByAddingObject:memCarried];
            }
        }

    // Values defined in the body (results + memory results) — used for the
    // post-loop escape remap to the final copy.
    NSMutableSet<NSNumber*>* bodyDefs = [NSMutableSet set];
    for (XTIRInsn* insn in B.instructions)
        {
        if (insn.result)
            [bodyDefs addObject:@(insn.result.valueId)];
        if (insn.memoryResult)
            [bodyDefs addObject:@(insn.memoryResult.valueId)];
        }

    // Current incoming value-id for each accumulator (copy 0 = its init).
    NSMutableDictionary<NSNumber*, NSNumber*>* carriedCur = [NSMutableDictionary dictionary];
    for (XTCarried* cr in c.carried)
        carriedCur[@(cr.phiId)] = @(cr.seedOp.valueId);

    NSMutableArray<XTIRBlock*>* clones = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, NSNumber*>* lastMap = nil;

    for (NSUInteger j = 0; j < c.trip; j++)
        {
        XTIRBlock* C = [[XTIRBlock alloc] init];
        C.name = [NSString stringWithFormat:@"%@_u%lu", B.name ?: @"body", (unsigned long)j];
        NSMutableDictionary<NSNumber*, NSNumber*>* map = [NSMutableDictionary dictionary];

        // iv → a fresh Const of its loop value for this copy.
        int64_t ivVal = c.startVal + (int64_t)j * c.step;
        XTIRValueId ivCid = [fn allocateValueId];
        XTIRValue* ivCval = [[XTIRValue alloc] initWithValueId:ivCid
                                                          type:c.ivType
                                                       defSite:[[XTIRDefSite alloc] initWithBlock:C insnIndex:0]];
        [fn registerValue:ivCval];
        XTIRInsn* ivConst = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                      result:ivCval
                                                    operands:@[ [XTIROperand immIWithType:c.ivType value:ivVal] ]
                                                      dbgLoc:nil];
        [C appendInstruction:ivConst];
        map[@(ivId)] = @(ivCid);

        // Each accumulator phi → its current incoming value for this copy.
        for (XTCarried* cr in c.carried)
            map[@(cr.phiId)] = carriedCur[@(cr.phiId)];

        // Clone each body instruction with fresh result/memResult ids.
        NSUInteger idx = 1;
        for (XTIRInsn* insn in B.instructions)
            {
            NSMutableArray<XTIROperand*>* newOps = [NSMutableArray arrayWithCapacity:insn.operands.count];
            for (XTIROperand* op in insn.operands)
                [newOps addObject:remapOp(op, map)];

            XTIRValue *newResult = nil, *newMem = nil;
            if (insn.result)
                {
                XTIRValueId rid = [fn allocateValueId];
                newResult = [[XTIRValue alloc] initWithValueId:rid
                                                          type:insn.result.type
                                                       defSite:[[XTIRDefSite alloc] initWithBlock:C insnIndex:idx]];
                [fn registerValue:newResult];
                }
            if (insn.memoryResult)
                {
                XTIRValueId mid = [fn allocateValueId];
                newMem = [[XTIRValue alloc] initWithValueId:mid
                                                       type:memTy
                                                    defSite:[[XTIRDefSite alloc] initWithBlock:C insnIndex:idx]];
                [fn registerValue:newMem];
                }
            XTIRInsn* clone;
            if (insn.callConv)
                clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                                  result:newResult
                                                operands:newOps
                                                callConv:insn.callConv
                                                  dbgLoc:insn.dbgLoc];
            else if (insn.opcode == XTIROpICmp || insn.opcode == XTIROpFCmp)
                clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                                  result:newResult
                                                operands:newOps
                                               predicate:insn.predicate
                                                  dbgLoc:insn.dbgLoc];
            else
                clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                                  result:newResult
                                                operands:newOps
                                                  dbgLoc:insn.dbgLoc];
            clone.memoryResult = newMem;
            [C appendInstruction:clone];
            if (insn.result)
                map[@(insn.result.valueId)] = @(newResult.valueId);
            if (insn.memoryResult)
                map[@(insn.memoryResult.valueId)] = @(newMem.valueId);
            idx++;
            }

        // Advance each accumulator to the value this copy produced (the body
        // `next`, remapped through this copy's map).
        for (XTCarried* cr in c.carried)
            {
            NSNumber* nn = map[@(cr.nextOp.valueId)] ?: @(cr.nextOp.valueId);
            carriedCur[@(cr.phiId)] = nn;
            }
        [clones addObject:C];
        lastMap = map;
        }

    // Wire terminators: c_j → c_{j+1}, last → E.
    for (NSUInteger j = 0; j < clones.count; j++)
        {
        XTIRBlock* target = (j + 1 < clones.count) ? clones[j + 1] : E;
        [clones[j] setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                           result:nil
                                                         operands:@[ [XTIROperand blockWithRef:target] ]
                                                           dbgLoc:nil]];
        }

    // Preheader: retarget any branch to H → first clone.
    [self retargetTerminatorOf:P fromBlock:H toBlock:clones.firstObject];

    // Escape remap for blocks outside the loop:
    //  * body-defined values → the final copy's clone (lastMap);
    //  * each accumulator phi result → its final carried value.
    NSMutableDictionary<NSNumber*, NSNumber*>* escape = [lastMap mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber*>* escapeDefs = [bodyDefs mutableCopy];
    for (XTCarried* cr in c.carried)
        {
        escape[@(cr.phiId)] = carriedCur[@(cr.phiId)];
        [escapeDefs addObject:@(cr.phiId)];
        }
    for (XTIRBlock* bb in fn.blocks)
        {
        if (bb == H || bb == B)
            continue;
        [self remapUsesIn:bb defs:escapeDefs to:escape];
        }

    // Splice: drop H and B, insert the clones where H was.
    NSUInteger pos = [fn.blocks indexOfObject:H];
    [fn.blocks removeObject:H];
    [fn.blocks removeObject:B];
    if (pos == NSNotFound || pos > fn.blocks.count)
        pos = fn.blocks.count;
    NSIndexSet* is = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(pos, clones.count)];
    [fn.blocks insertObjects:clones atIndexes:is];
    }

// Rebuild `blk`'s terminator replacing block operand `from` with `to`.
- (void)retargetTerminatorOf:(XTIRBlock*)blk fromBlock:(XTIRBlock*)from toBlock:(XTIRBlock*)to
    {
    XTIRInsn* t = blk.terminator;
    if (!t)
        return;
    BOOL changed = NO;
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:t.operands.count];
    for (XTIROperand* op in t.operands)
        {
        if (op.kind == XTIROperandKindBlock && op.blockRef == from)
            {
            [ops addObject:[XTIROperand blockWithRef:to]];
            changed = YES;
            }
        else
            [ops addObject:op];
        }
    if (!changed)
        return;
    XTIRInsn* nt = [[XTIRInsn alloc] initWithOpcode:t.opcode
                                             result:t.result
                                           operands:ops
                                          predicate:t.predicate
                                             dbgLoc:t.dbgLoc];
    nt.memoryResult = t.memoryResult;
    [blk resetTerminator];
    [blk setTerminator:nt];
    }

// Rewrite uses of any id in `defs` to `map[id]`, across phis/insns/terminator.
- (void)remapUsesIn:(XTIRBlock*)blk
               defs:(NSSet<NSNumber*>*)defs
                 to:(NSDictionary<NSNumber*, NSNumber*>*)map
    {
    NSArray<XTIROperand*>* (^rew)(XTIRInsn*) = ^NSArray*(XTIRInsn* insn) {
      NSMutableArray<XTIROperand*>* out = nil;
      for (NSUInteger i = 0; i < insn.operands.count; i++)
          {
          XTIROperand* op = insn.operands[i];
          if (op.kind == XTIROperandKindUse && [defs containsObject:@(op.valueId)])
              {
              NSNumber* n = map[@(op.valueId)];
              if (n)
                  {
                  if (!out)
                      out = [insn.operands mutableCopy];
                  out[i] = [XTIROperand useWithValueId:(XTIRValueId)n.unsignedLongLongValue];
                  }
              }
          }
      return out;
    };
    XTIRInsn* (^rebuild)(XTIRInsn*, NSArray<XTIROperand*>*) =
        ^XTIRInsn*(XTIRInsn* insn, NSArray<XTIROperand*>* no) {
          XTIRInsn* r;
          if (insn.callConv)
              r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                            result:insn.result
                                          operands:no
                                          callConv:insn.callConv
                                            dbgLoc:insn.dbgLoc];
          else if (insn.opcode == XTIROpICmp || insn.opcode == XTIROpFCmp)
              r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                            result:insn.result
                                          operands:no
                                         predicate:insn.predicate
                                            dbgLoc:insn.dbgLoc];
          else
              r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                            result:insn.result
                                          operands:no
                                            dbgLoc:insn.dbgLoc];
          r.memoryResult = insn.memoryResult;
          return r;
        };
    for (NSUInteger i = 0; i < blk.phiNodes.count; i++)
        {
        NSArray* no = rew(blk.phiNodes[i]);
        if (no)
            blk.phiNodes[i] = rebuild(blk.phiNodes[i], no);
        }
    for (NSUInteger i = 0; i < blk.instructions.count; i++)
        {
        NSArray* no = rew(blk.instructions[i]);
        if (no)
            blk.instructions[i] = rebuild(blk.instructions[i], no);
        }
    if (blk.terminator)
        {
        NSArray* no = rew(blk.terminator);
        if (no)
            {
            XTIRInsn* nt = rebuild(blk.terminator, no);
            [blk resetTerminator];
            [blk setTerminator:nt];
            }
        }
    }

@end
