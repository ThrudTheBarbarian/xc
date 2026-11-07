#import "XTIROptLoopUnrollVarTrip.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"

// How many body copies per back-edge. 4 matches the common clang choice; the
// OoO host hides most of the cross-iteration overlap anyway, so larger factors
// buy little and bloat code.
static const NSUInteger kUnrollFactor = 4;
// Skip bodies above this size — the unroll multiplies code by kUnrollFactor and
// a huge body isn't branch-bound anyway.
static const NSUInteger kMaxBodyInsns = 48;

// A recognised single-block-body variable-trip loop.
@interface XTVarTripCand : NSObject
@property(nonatomic) XTIRBlock* header; // H: holds the iv phi + guard
@property(nonatomic) XTIRBlock* body;   // B: single-block body, latch → H
@property(nonatomic) XTIRBlock* exit;   // E: loop exit (no phis)
@property(nonatomic) XTIRInsn* ivPhi;   // induction phi (in H)
@property(nonatomic) XTIRInsn* guard;   // ICmp feeding H's CondBranch
@property(nonatomic) XTIRInsn* ivNext;  // Add(iv, step) in B (phi back-edge)
@property(nonatomic) XTIRValueId ivId;
@property(nonatomic) XTIROperand* step; // the loop-invariant addend of ivNext
@property(nonatomic) BOOL stepIsConst;  // step resolves to a known constant
@property(nonatomic) int64_t stepConstVal;
// YES when the trip count is a compile-time constant that divides EXACTLY by
// the unroll factor. The intermediate copies' guards are then provably true and
// are not emitted at all — three instructions per copy that only exist because
// this unroller assumes a variable trip.
@property(nonatomic) BOOL exactTrip;
// YES when the body computes vector values. Both the guard removal and the
// pointer re-basing below are gated on it: each trades a longer live range for
// fewer instructions, which a vector body (its values in the separate v18-v31
// pool) absorbs and a GP-bound scalar body pays for in spills.
@property(nonatomic) BOOL vectorBody;
// Extra carried values (reductions/accumulators) threaded through the loop
// alongside the induction variable, parallel arrays indexed together:
@property(nonatomic) NSArray<XTIRInsn*>* redPhis;    // the accumulator phis in H
@property(nonatomic) NSArray<XTIRInsn*>* redNexts;   // their back-edge update insns (in B)
@property(nonatomic) NSArray<NSNumber*>* redIds;     // redPhis[i].result.valueId
@property(nonatomic) NSArray<NSNumber*>* redEscapes; // BOOL: result used outside H/B (needs exit phi)
@end
@implementation XTVarTripCand
@end

@implementation XTIROptLoopUnrollVarTrip

- (NSString*)passName
    {
    return @"loop-unroll-vartrip";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (!prof.unrollsVariableTrip)
        return YES;
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn];
    return YES;
    }

static BOOL isCallOpcode(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpCall:
    case XTIROpCallBanked:
    case XTIROpCallCloaked:
        return YES;
    default:
        return NO;
        }
    }

// Resolve an operand to a constant integer, seeing through a widen/narrow of a
// constant (a `u16 i += 1` lowers the step as ZExt(Const #1:U8), so the raw
// operand is a cast, not a Const). Returns YES and sets *out on success.
static BOOL resolveConstInt(XTIROperand* op, NSDictionary<NSNumber*, XTIRInsn*>* defOf,
                            int64_t* out)
    {
    if (op.kind == XTIROperandKindImmI)
        {
        *out = op.intValue;
        return YES;
        }
    if (op.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* d = defOf[@(op.valueId)];
    if (!d || d.operands.count < 1)
        return NO;
    if (d.opcode == XTIROpConst && d.operands[0].kind == XTIROperandKindImmI)
        {
        *out = d.operands[0].intValue;
        return YES;
        }
    if (d.opcode == XTIROpZExt || d.opcode == XTIROpSExt || d.opcode == XTIROpTrunc)
        return resolveConstInt(d.operands[0], defOf, out);
    return NO;
    }

// Remap a Use operand through `map`; other operand kinds unchanged.
static XTIROperand* remapOp(XTIROperand* op, NSDictionary<NSNumber*, NSNumber*>* map)
    {
    if (op.kind != XTIROperandKindUse)
        return op;
    NSNumber* n = map[@(op.valueId)];
    return n ? [XTIROperand useWithValueId:(XTIRValueId)n.unsignedLongLongValue] : op;
    }

// Rebuild an insn with new operands/result, preserving predicate/memoryResult.
// (Call bodies are rejected, so callConv never appears here.)
static XTIRInsn* buildLike(XTIRInsn* insn, XTIRValue* _Nullable result,
                           NSArray<XTIROperand*>* ops, XTIRValue* _Nullable memResult)
    {
    XTIRInsn* r;
    if (XTIROpCarriesPredicate(insn.opcode))
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:result
                                    operands:ops
                                   predicate:insn.predicate
                                      dbgLoc:insn.dbgLoc];
    else
        r = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                      result:result
                                    operands:ops
                                      dbgLoc:insn.dbgLoc];
    r.memoryResult = memResult;
    return r;
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    // One loop at a time, re-recognising after each transform (the apply
    // rewrites the CFG; a fresh scan avoids stale captured blocks). An unrolled
    // loop's body is no longer single-block, so it won't re-match — the bound is
    // just a runaway backstop.
    for (NSUInteger iter = 0; iter < 256; iter++)
        {
        XTVarTripCand* c = [self recognise:fn];
        if (!c)
            break;
        [self apply:c inFunction:fn];
        }
    }

- (nullable XTVarTripCand*)recognise:(XTIRFunction*)fn
    {
    // Definition site + use multiplicity for the whole function.
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    NSCountedSet<NSNumber*>* uses = [NSCountedSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn.result)
                {
                defOf[@(insn.result.valueId)] = insn;
                defBlk[@(insn.result.valueId)] = bb;
                }
            for (XTIROperand* o in insn.operands)
                if (o.kind == XTIROperandKindUse)
                    [uses addObject:@(o.valueId)];
            }
        }

    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    BOOL allowMulti = prof.unrollAllowsMultipleCarriedValues;

    for (XTIRBlock* H in fn.blocks)
        {
        // At least the induction phi; loose memory ⇒ no mem phi. A second carried
        // value (a reduction/accumulator) is allowed only where the profile says
        // so — the unrolled copies serial-chain it (order preserved), and any
        // escaping accumulator gets an exit phi built in apply.
        if (H.phiNodes.count == 0)
            continue;
        if (H.phiNodes.count > 1 && !allowMulti)
            continue;
        // Skip the vectoriser's reduction loops: it has already unrolled them
        // into several vector accumulators. A loop with ONE vector accumulator
        // is an outer-vectorised one, which nothing else unrolls; the copies
        // chain it serially like any carried value, so no lane changes order.
        NSUInteger vecPhis = 0;
        for (XTIRInsn* p in H.phiNodes)
            if (p.result && p.result.type.kind == XTIRTypeKindVec)
                vecPhis++;
        if (vecPhis > 1)
            continue;

        // The header must be side-effect free (it runs once per N bodies after
        // unrolling, so a store/load/call there would change how often it fires).
        BOOL headerPure = YES;
        for (XTIRInsn* insn in H.instructions)
            if (insn.memoryResult || isCallOpcode(insn.opcode))
                {
                headerPure = NO;
                break;
                }
        if (!headerPure)
            continue;

        // Terminator: CondBranch on an ICmp.
        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || defBlk[@(term.operands[0].valueId)] != H)
            continue;
        if (guard.operands.count < 2)
            continue;

        // The induction phi is the H phi the guard tests directly; the rest are
        // reduction candidates.
        XTIRInsn* ivPhi = nil;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.memoryResult)
                continue;
            for (XTIROperand* o in guard.operands)
                if (o.kind == XTIROperandKindUse && o.valueId == phi.result.valueId)
                    {
                    ivPhi = phi;
                    break;
                    }
            if (ivPhi)
                break;
            }
        if (!ivPhi)
            continue;
        XTIRType* ivTy = ivPhi.result.type;
        if (!ivTy || !XTIRTypeKindIsInteger(ivTy.kind))
            continue;
        XTIRValueId ivId = ivPhi.result.valueId;

        // The body is whichever target branches back to H unconditionally; the
        // other target is the loop exit.
        XTIRBlock *T = term.operands[1].blockRef, *F = term.operands[2].blockRef;
        BOOL (^latches)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b && b != H && b.terminator && b.terminator.opcode == XTIROpBranch &&
                 b.terminator.operands.count >= 1 &&
                 b.terminator.operands[0].blockRef == H;
        };
        XTIRBlock *B = nil, *E = nil;
        if (latches(T))
            {
            B = T;
            E = F;
            }
        else if (latches(F))
            {
            B = F;
            E = T;
            }
        else
            continue;
        if (!E || B.phiNodes.count != 0 || E.phiNodes.count != 0)
            continue;
        if (B.instructions.count == 0 || B.instructions.count > kMaxBodyInsns)
            continue;

        // Body must be call-free (loose-memory load/store bodies only). Vector
        // ops are allowed: a vectorised *map* loop (no Vec accumulator phi — those
        // are filtered above and unrolled by the reduction unroller) benefits from
        // the same partial unroll, and the clone path handles VLoad/VStore mem
        // tokens like any other. The horizontal-reduce ops never appear here (they
        // live in the exit block, not the loop body).
        BOOL bodyOK = YES;
        for (XTIRInsn* insn in B.instructions)
            if (isCallOpcode(insn.opcode) ||
                insn.opcode == XTIROpVReduceAdd || insn.opcode == XTIROpVReduceMax ||
                insn.opcode == XTIROpVReduceMin)
                {
                bodyOK = NO;
                break;
                }
        if (!bodyOK)
            continue;

        // iv phi incomings: (preheader, init) + (B, ivNext). Find the B one.
        if (ivPhi.operands.count != 4)
            continue;
        XTIROperand* nextOp = nil;
        if (ivPhi.operands[0].blockRef == B)
            nextOp = ivPhi.operands[1];
        else if (ivPhi.operands[2].blockRef == B)
            nextOp = ivPhi.operands[3];
        if (!nextOp || nextOp.kind != XTIROperandKindUse)
            continue;

        // ivNext = Add(iv, step) in B, used only by the phi, step not body-defined.
        XTIRInsn* ivNext = defOf[@(nextOp.valueId)];
        if (!ivNext || ivNext.opcode != XTIROpAdd || defBlk[@(nextOp.valueId)] != B)
            continue;
        if ([uses countForObject:@(nextOp.valueId)] != 1)
            continue; // back-edge only
        if (ivNext.operands.count < 2)
            continue;
        XTIROperand *a0 = ivNext.operands[0], *a1 = ivNext.operands[1];
        XTIROperand* stepOp = nil;
        if (a0.kind == XTIROperandKindUse && a0.valueId == ivId)
            stepOp = a1;
        else if (a1.kind == XTIROperandKindUse && a1.valueId == ivId)
            stepOp = a0;
        if (!stepOp)
            continue;
        // The step must not vary with iv (a per-copy clone would recompute a
        // different value). A value defined outside the body is loop-invariant; a
        // body-defined step is safe iff it resolves to a constant (a Const, or a
        // widen/narrow of one — the usual shape of a u8/u16 counter's `+= 1`),
        // since each copy just re-materialises the same constant.
        int64_t stepK = 0;
        BOOL stepConst = resolveConstInt(stepOp, defOf, &stepK);
        if (stepOp.kind == XTIROperandKindUse && defBlk[@(stepOp.valueId)] == B && !stepConst)
            continue;

        // The guard bound must not be defined in the body either (the cloned
        // guards reference it from outside the removed block).
        BOOL boundOK = YES;
        for (XTIROperand* o in guard.operands)
            if (o.kind == XTIROperandKindUse && o.valueId != ivId && defBlk[@(o.valueId)] == B)
                {
                boundOK = NO;
                break;
                }
        if (!boundOK)
            continue;

        // iv must not escape the loop (no exit phi to materialise its final
        // value); its only outside-H/B use would force that.
        BOOL ivEscapes = NO;
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
            [all addObjectsFromArray:bb.phiNodes];
            [all addObjectsFromArray:bb.instructions];
            if (bb.terminator)
                [all addObject:bb.terminator];
            for (XTIRInsn* insn in all)
                for (XTIROperand* o in insn.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == ivId)
                        {
                        ivEscapes = YES;
                        break;
                        }
            if (ivEscapes)
                break;
            }
        if (ivEscapes)
            continue;

        // Every non-induction phi in H is a carried reduction/accumulator. Each
        // must have the standard (preheader-init, body-update) shape with the
        // update defined in B and used only by the phi (back-edge only) — then
        // the unrolled copies can serial-chain it (preserving order, so no
        // associativity requirement; float reductions are fine). If any phi
        // doesn't fit, don't unroll this loop.
        NSMutableArray<XTIRInsn*>* redPhis = [NSMutableArray array];
        NSMutableArray<XTIRInsn*>* redNexts = [NSMutableArray array];
        NSMutableArray<NSNumber*>* redIds = [NSMutableArray array];
        NSMutableArray<NSNumber*>* redEsc = [NSMutableArray array];
        BOOL redOK = YES;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (phi == ivPhi)
                continue;
            XTIRType* rt = phi.result.type;
            if (!phi.result || phi.memoryResult || phi.operands.count != 4 || !rt ||
                rt.kind == XTIRTypeKindAgg || rt.kind == XTIRTypeKindMemory ||
                rt.kind == XTIRTypeKindVoid)
                {
                redOK = NO;
                break;
                }
            XTIROperand* rNextOp = nil;
            if (phi.operands[0].blockRef == B)
                rNextOp = phi.operands[1];
            else if (phi.operands[2].blockRef == B)
                rNextOp = phi.operands[3];
            if (!rNextOp || rNextOp.kind != XTIROperandKindUse)
                {
                redOK = NO;
                break;
                }
            XTIRInsn* rNext = defOf[@(rNextOp.valueId)];
            if (!rNext || defBlk[@(rNextOp.valueId)] != B)
                {
                redOK = NO;
                break;
                }
            if ([uses countForObject:@(rNextOp.valueId)] != 1)
                {
                redOK = NO;
                break;
                }
            XTIRValueId rId = phi.result.valueId;
            // Does the carried value's result escape the loop (used outside H/B)?
            // If so apply must materialise it at every loop exit via an exit phi.
            BOOL esc = NO;
            for (XTIRBlock* bb in fn.blocks)
                {
                if (bb == H || bb == B)
                    continue;
                NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
                [all addObjectsFromArray:bb.phiNodes];
                [all addObjectsFromArray:bb.instructions];
                if (bb.terminator)
                    [all addObject:bb.terminator];
                for (XTIRInsn* insn in all)
                    for (XTIROperand* o in insn.operands)
                        if (o.kind == XTIROperandKindUse && o.valueId == rId)
                            {
                            esc = YES;
                            break;
                            }
                if (esc)
                    break;
                }
            [redPhis addObject:phi];
            [redNexts addObject:rNext];
            [redIds addObject:@(rId)];
            [redEsc addObject:@(esc)];
            }
        if (!redOK)
            continue;

        // If any accumulator escapes, apply builds an exit phi in E whose
        // incomings are H + the intermediate clones. That covers all of E's
        // edges only if, pre-unroll, E is reached solely from H — otherwise an
        // external predecessor would leave the exit phi missing an incoming.
        BOOL anyEsc = NO;
        for (NSNumber* e in redEsc)
            if (e.boolValue)
                {
                anyEsc = YES;
                break;
                }
        if (anyEsc)
            {
            NSUInteger ePreds = 0;
            BOOL onlyH = YES;
            for (XTIRBlock* bb in fn.blocks)
                {
                XTIRInsn* tt = bb.terminator;
                if (!tt)
                    continue;
                for (XTIROperand* o in tt.operands)
                    if (o.kind == XTIROperandKindBlock && o.blockRef == E)
                        {
                        ePreds++;
                        if (bb != H)
                            onlyH = NO;
                        break;
                        }
                }
            if (!onlyH || ePreds != 1)
                continue;
            }

        XTVarTripCand* c = [XTVarTripCand new];
        c.header = H;
        c.body = B;
        c.exit = E;
        c.ivPhi = ivPhi;
        c.guard = guard;
        c.ivNext = ivNext;
        c.ivId = ivId;
        c.redPhis = redPhis;
        c.redNexts = redNexts;
        c.redIds = redIds;
        c.redEscapes = redEsc;
        // Resolve the step to a constant when possible (ImmI, or a Const def);
        // a non-constant step is loop-invariant and defined outside B (the
        // in-B-must-be-Const check above), so it stays referenceable after B
        // is removed. This lets `apply` form the carried update iv_0 + N*step.
        c.step = stepOp;
        c.stepIsConst = stepConst;
        c.stepConstVal = stepK;

        // A CONSTANT trip that is a whole number of unrolled groups needs no
        // per-copy guard. The vectoriser leaves exactly this behind: array_map
        // counts 0..4096 stepping by 4, which is 1024 iterations and 256 groups
        // of four, so copies 1..3 were testing a condition that cannot fail.
        //
        // Only a STRICT `<` with the iv on the left gives trip = (N - S) / step;
        // with `<=` the trip is one more and the arithmetic below would be off
        // by one in the unsafe direction.
        // ...or a FLOATING-POINT body, for the same reason. The gate is about
        // what the body's values compete for: a vector body uses v18-v31 and an
        // FP body d8-d15, so in both cases the GP traffic is a few pointers and
        // lengthening a GP live range to save instructions is a good trade. A
        // GP-bound integer body is the case that spills instead.
        c.vectorBody = NO;
        for (XTIRInsn* bi in B.instructions)
            if (bi.result && bi.result.type &&
                (bi.result.type.kind == XTIRTypeKindVec ||
                 XTIRTypeKindIsFloating(bi.result.type.kind)))
                { c.vectorBody = YES; break; }
        c.exactTrip = NO;
        if (stepConst && stepK > 0 &&
            (guard.predicate == XTIRICmpULT || guard.predicate == XTIRICmpSLT) &&
            guard.operands.count >= 2 &&
            guard.operands[0].kind == XTIROperandKindUse &&
            guard.operands[0].valueId == ivId)
            {
            int64_t boundK = 0, startK = 0;
            XTIROperand* initOp = nil;
            for (NSUInteger k = 0; k + 1 < ivPhi.operands.count; k += 2)
                if (ivPhi.operands[k].blockRef != B)
                    initOp = ivPhi.operands[k + 1];
            if (initOp && resolveConstInt(guard.operands[1], defOf, &boundK) &&
                resolveConstInt(initOp, defOf, &startK))
                {
                int64_t span = boundK - startK;
                int64_t group = stepK * (int64_t)kUnrollFactor;
                // This used to be restricted to a VECTOR body. Dropping the
                // guards merges the copies into one straight-line run, which
                // lengthens every live range in it, and a scalar body then
                // spilled where a vector one (living in the separate v18-v31
                // pool) did not: array_map was 44% faster without the guards
                // and bit_ops 5% slower.
                //
                // That was the live-interval bug, not a property of scalar
                // bodies — every interval in the function shared one start, so
                // lengthening any of them cost a register nothing could get
                // back. With that fixed the restriction costs and buys
                // nothing: re-measured, bit_ops is unchanged and matrix_mul is
                // 17% faster with the guards gone.
                if (span > 0 && group > 0 && span % group == 0)
                    c.exactTrip = YES;
                }
            }
        if (self.exactOnly && !c.exactTrip)
            continue;
        return c;
        }
    return nil;
    }

// In a par kernel the unrolled loop counts its groups by one, and each copy's
// induction value is start + g*U*step (issue #7). Mesa's compiler for the Pi
// 5's V3D runs a loop counted by one far faster than the same loop counted by
// four: nbody's inner loop 32.5 ms against 66.2 ms, the bodies otherwise the
// same. Only an exact trip (constant start and bound), with the induction value
// read in the header by the guard alone.
- (void)countGroups:(XTVarTripCand*)c
         inFunction:(XTIRFunction*)fn
             clones:(NSArray<XTIRBlock*>*)clones
         lastIvNext:(XTIRValueId)lastIvNext
    {
    if (!self.exactOnly || !c.exactTrip || !c.stepIsConst || clones.count == 0)
        return;
    XTIRBlock* H = c.header;
    XTIRValueId ivId = c.ivId;
    XTIRBlock* first = clones.firstObject;
    XTIRBlock* last = clones.lastObject;
    XTIRInsn* ivPhi = nil;
    for (XTIRInsn* p in H.phiNodes)
        if (p.result && p.result.valueId == ivId)
            {
            ivPhi = p;
            break;
            }
    if (!ivPhi || !H.terminator || H.terminator.operands.count < 1 ||
        H.terminator.operands[0].kind != XTIROperandKindUse)
        return;
    XTIRInsn* guard = nil;
    for (XTIRInsn* n in H.instructions)
        if (n.result && n.result.valueId == H.terminator.operands[0].valueId)
            guard = n;
    if (!guard || guard.opcode != XTIROpICmp || guard.operands.count < 2)
        return;
    BOOL (^usesIv)(XTIRInsn*) = ^BOOL(XTIRInsn* n) {
        for (XTIROperand* o in n.operands)
            if (o.kind == XTIROperandKindUse && o.valueId == ivId)
                return YES;
        return NO;
    };
    for (XTIRInsn* n in H.instructions)
        if (n != guard && usesIv(n))
            return;
    for (XTIRInsn* n in H.phiNodes)
        if (n != ivPhi && usesIv(n))
            return;
    XTIRBlock* pre = nil;
    XTIROperand* initOp = nil;
    for (NSUInteger k = 0; k + 1 < ivPhi.operands.count; k += 2)
        if (ivPhi.operands[k].blockRef != last)
            {
            pre = ivPhi.operands[k].blockRef;
            initOp = ivPhi.operands[k + 1];
            }
    if (!pre || !initOp)
        return;
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* n in bb.phiNodes)
            if (n.result)
                defOf[@(n.result.valueId)] = n;
        for (XTIRInsn* n in bb.instructions)
            if (n.result)
                defOf[@(n.result.valueId)] = n;
        }
    int64_t startK = 0, boundK = 0;
    if (!resolveConstInt(initOp, defOf, &startK) || !resolveConstInt(guard.operands[1], defOf, &boundK))
        return;
    int64_t group = c.stepConstVal * (int64_t)kUnrollFactor;
    if (group <= 0)
        return;
    int64_t groups = (boundK - startK) / group;
    if (groups <= 0 || groups > INT32_MAX)
        return;
    XTIRType* ty = ivPhi.result.type;
    XTIRValue* (^fresh)(XTIRBlock*, NSUInteger) = ^XTIRValue*(XTIRBlock* blk, NSUInteger at) {
        XTIRValue* v = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                     type:ty
                                                  defSite:[[XTIRDefSite alloc] initWithBlock:blk insnIndex:at]];
        [fn registerValue:v];
        return v;
    };

    // g: 0 from the preheader, g + 1 round the back edge.
    XTIRValue* z = fresh(pre, pre.instructions.count);
    [pre.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                     result:z
                                                   operands:@[ [XTIROperand immIWithType:ty value:0] ]
                                                     dbgLoc:nil]];
    XTIRValue* g = fresh(H, 0);
    XTIRValue* gn = fresh(last, last.instructions.count);
    [last.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                      result:gn
                                                    operands:@[ [XTIROperand useWithValueId:g.valueId],
                                                                [XTIROperand immIWithType:ty value:1] ]
                                                      dbgLoc:nil]];
    [H.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                    result:g
                                                  operands:@[ [XTIROperand blockWithRef:pre], [XTIROperand useWithValueId:z.valueId],
                                                              [XTIROperand blockWithRef:last], [XTIROperand useWithValueId:gn.valueId] ]
                                                    dbgLoc:nil]];
    NSMutableArray<XTIROperand*>* gops = [guard.operands mutableCopy];
    gops[0] = [XTIROperand useWithValueId:g.valueId];
    gops[1] = [XTIROperand immIWithType:ty value:groups];
    [guard replaceOperands:gops];

    // The copies' induction value, from g at the top of the first.
    XTIRValue* mv = fresh(first, 0);
    XTIRInsn* mul = [[XTIRInsn alloc] initWithOpcode:XTIROpMul
                                              result:mv
                                            operands:@[ [XTIROperand useWithValueId:g.valueId],
                                                        [XTIROperand immIWithType:ty value:group] ]
                                              dbgLoc:c.ivNext.dbgLoc];
    XTIRValue* av = fresh(first, 1);
    XTIRInsn* add = [[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                              result:av
                                            operands:@[ [XTIROperand useWithValueId:mv.valueId], initOp ]
                                              dbgLoc:c.ivNext.dbgLoc];
    [first.instructions insertObject:add atIndex:0];
    [first.instructions insertObject:mul atIndex:0];
    for (XTIRBlock* C in clones)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:C.instructions];
        if (C.terminator)
            [all addObject:C.terminator];
        for (XTIRInsn* n in all)
            {
            if (n == mul || n == add || !usesIv(n))
                continue;
            NSMutableArray<XTIROperand*>* ops = [n.operands mutableCopy];
            for (NSUInteger k = 0; k < ops.count; k++)
                if (ops[k].kind == XTIROperandKindUse && ops[k].valueId == ivId)
                    ops[k] = [XTIROperand useWithValueId:av.valueId];
            [n replaceOperands:ops];
            }
        }

    // The old induction is dead: its phi, and the back-edge add.
    [H.phiNodes removeObjectIdenticalTo:ivPhi];
    for (NSUInteger i = 0; i < last.instructions.count; i++)
        if (last.instructions[i].result && last.instructions[i].result.valueId == lastIvNext)
            {
            [last.instructions removeObjectAtIndex:i];
            break;
            }
    }

- (void)apply:(XTVarTripCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock *H = c.header, *B = c.body, *E = c.exit;
    XTIRValueId ivId = c.ivId;
    XTIRType* memTy = [XTIRType memoryType];

    NSMutableArray<XTIRBlock*>* clones = [NSMutableArray array];
    NSMutableArray<XTIRValue*>* guardResults = [NSMutableArray array]; // per copy (nil for last)
    XTIRValueId prevIv = ivId;                                         // iv_0 = the header phi result
    XTIRValueId lastIvNext = ivId;

    // Reduction threading: each carried accumulator is serial-chained through
    // the copies (acc_0 → acc_1 → … → acc_N, order preserved). prevRed[i] is the
    // value entering the current copy; accAfter[i][j] is the value after copy j
    // (used to build exit phis for escaping accumulators); lastRed[i] feeds the
    // back-edge.
    NSUInteger nred = c.redPhis.count;
    NSMutableArray<NSNumber*>* prevRed = [NSMutableArray array];
    NSMutableArray<NSNumber*>* lastRed = [NSMutableArray array];
    NSMutableArray<NSMutableArray<NSNumber*>*>* accAfter = [NSMutableArray array];
    for (NSUInteger i = 0; i < nred; i++)
        {
        [prevRed addObject:c.redIds[i]];
        [lastRed addObject:c.redIds[i]];
        [accAfter addObject:[NSMutableArray array]];
        }

    NSMutableDictionary<NSNumber*, NSNumber*>* lastMap = nil;
    // A pure LOOP-INVARIANT body instruction (a VSplat of an outer-loop value
    // the vectoriser left in the body, or the Const/cast chain feeding it)
    // computes the same value in every copy: clone it once, in copy 0, and let
    // the later copies reference that result — copy 0 dominates them (the
    // copies chain straight-line). One live broadcast instead of U is what
    // keeps the backends' 8-register vector pools from overflowing (#1198,
    // sum=272449664: U splats plus the reduction accumulators exceeded the
    // pool and the silent overflow reused a live splat's register).
    // orig result id → copy-0 clone id, for results proven invariant.
    NSMutableDictionary<NSNumber*, NSNumber*>* sharedPure = [NSMutableDictionary dictionary];
    for (NSUInteger j = 0; j < kUnrollFactor; j++)
        {
        XTIRBlock* C = [[XTIRBlock alloc] init];
        C.name = [NSString stringWithFormat:@"%@_vu%lu", B.name ?: @"body", (unsigned long)j];
        NSUInteger idx = 0;
        NSMutableDictionary<NSNumber*, NSNumber*>* map = [NSMutableDictionary dictionary];
        map[@(ivId)] = @(prevIv); // remap iv → this copy's incoming value
        for (NSUInteger i = 0; i < nred; i++)
            map[c.redIds[i]] = prevRed[i];
        // In a par kernel each copy's induction value is copy 0's plus j steps,
        // not the previous copy's plus one: the GPU's compiler folds a constant
        // offset from one base into each load, and does not fold a chain
        // (nbody on the Pi 5's V3D: 66.3 ms chained, 32.5 ms re-based; issue
        // #7).
        if (self.exactOnly && j > 0 && c.stepIsConst)
            {
            XTIRType* ivTy = c.ivNext.result.type;
            XTIRValueId vid = [fn allocateValueId];
            XTIRValue* v = [[XTIRValue alloc] initWithValueId:vid
                                                         type:ivTy
                                                      defSite:[[XTIRDefSite alloc] initWithBlock:C insnIndex:idx]];
            [fn registerValue:v];
            [C appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                           result:v
                                                         operands:@[ [XTIROperand useWithValueId:ivId],
                                                                     [XTIROperand immIWithType:ivTy value:c.stepConstVal * (int64_t)j] ]
                                                           dbgLoc:c.ivNext.dbgLoc]];
            idx++;
            map[@(ivId)] = @(vid);
            }

        // A POINTER carried by a constant stride is re-based on copy 0 rather
        // than chained. The chain `p -> p+16 -> p+32 -> p+48` costs one `add`
        // per copy per array; `p+0, p+16, p+32, p+48` costs none, because the
        // back end already folds ElementAddr(base, CONSTANT) into the
        // `ldr/str q, [base, #imm]` addressing mode. mem_copy carries two
        // pointers over four copies — eight adds on a twenty-instruction body.
        //
        // Only copies after the first, and only when the carried update is
        // exactly ElementAddr(phi, K) with K a literal: anything else keeps the
        // chain. The LAST copy's update still produces the back-edge value, so
        // the loop still advances by U*K once per iteration.
        // The update of a re-based pointer is re-based too: it is p + K*(j+1)
        // straight from the phi, not (p + K*j) + K. In the last copy that is
        // the back-edge value, which was otherwise a chain of two adds.
        NSMutableDictionary<NSNumber*, NSArray*>* rebasedNext = [NSMutableDictionary dictionary];
        if (j > 0)
            {
            for (NSUInteger i = 0; i < nred; i++)
                {
                XTIRInsn* rn = (XTIRInsn*)c.redNexts[i];
                XTIRInsn* rp = (XTIRInsn*)c.redPhis[i];
                if (!rn || !rp || rn.opcode != XTIROpElementAddr || rn.operands.count < 2)
                    continue;
                if (rn.operands[0].kind != XTIROperandKindUse ||
                    rn.operands[0].valueId != rp.result.valueId)
                    continue;
                if (rn.operands[1].kind != XTIROperandKindImmI)
                    continue;
                if (!rp.result.type || rp.result.type.kind != XTIRTypeKindPtr)
                    continue;
                int64_t stride = rn.operands[1].intValue;
                XTIRValueId rid = [fn allocateValueId];
                XTIRValue* rv = [[XTIRValue alloc] initWithValueId:rid
                                                              type:rp.result.type
                                                           defSite:[[XTIRDefSite alloc] initWithBlock:C
                                                                                           insnIndex:idx]];
                [fn registerValue:rv];
                [C appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpElementAddr
                                                               result:rv
                                                             operands:@[ [XTIROperand useWithValueId:c.redIds[i].unsignedLongLongValue],
                                                                         [XTIROperand immIWithType:rn.operands[1].type
                                                                                             value:stride * (int64_t)j] ]
                                                               dbgLoc:rn.dbgLoc]];
                idx++;
                map[c.redIds[i]] = @(rid);
                rebasedNext[@(rn.result.valueId)] = @[ c.redIds[i], rn.operands[1].type, @(stride * (int64_t)(j + 1)) ];
                }
            }

        XTIRValueId cloneIvNext = prevIv;
        // A re-based pointer update is appended at the END of the copy, after
        // the last access through the old pointer, so the two never overlap and
        // the register allocator can give the new value the old one's register
        // (no copy at the back edge). Only when nothing in the body reads it.
        NSMutableArray<XTIRInsn*>* deferred = [NSMutableArray array];
        for (XTIRInsn* insn in B.instructions)
            {
            // Invariant iff every Use operand is either defined outside the
            // body (not remapped) or itself a shared invariant clone.
            BOOL shareable = NO;
            if (insn.result && !insn.memoryResult && insn != c.ivNext &&
                (insn.opcode == XTIROpVSplat || insn.opcode == XTIROpConst ||
                 insn.opcode == XTIROpZExt || insn.opcode == XTIROpSExt ||
                 insn.opcode == XTIROpTrunc))
                {
                shareable = YES;
                for (XTIROperand* o in insn.operands)
                    if (o.kind == XTIROperandKindUse && map[@(o.valueId)] &&
                        !sharedPure[@(o.valueId)])
                        {
                        shareable = NO;
                        break;
                        }
                // A splat of a value the body defines (a constant the
                // vectoriser left in the body, past its hoisting budget) is
                // made again in each copy: shared, it would be live across all
                // of them, and MD5's rounds have dozens.
                if (insn.opcode == XTIROpVSplat && insn.operands.count == 1 &&
                    insn.operands[0].kind == XTIROperandKindUse && map[@(insn.operands[0].valueId)])
                    shareable = NO;
                // In a large body none is: each is a register the copies' own
                // values need.
                if (insn.opcode == XTIROpVSplat && B.instructions.count > XTIR_VEC_SPLAT_BIG_BODY)
                    shareable = NO;
                }
            if (shareable && sharedPure[@(insn.result.valueId)])
                {
                map[@(insn.result.valueId)] = sharedPure[@(insn.result.valueId)];
                continue; // copies 1..U-1 reuse copy 0's
                }
            NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:insn.operands.count];
            NSArray* rb = insn.result ? rebasedNext[@(insn.result.valueId)] : nil;
            if (rb)
                {
                [ops addObject:[XTIROperand useWithValueId:[rb[0] unsignedLongLongValue]]];
                [ops addObject:[XTIROperand immIWithType:rb[1] value:[rb[2] longLongValue]]];
                }
            else
                for (XTIROperand* op in insn.operands)
                    [ops addObject:remapOp(op, map)];
            XTIRValue *newRes = nil, *newMem = nil;
            if (insn.result)
                {
                XTIRValueId rid = [fn allocateValueId];
                newRes = [[XTIRValue alloc] initWithValueId:rid
                                                       type:insn.result.type
                                                    defSite:[[XTIRDefSite alloc] initWithBlock:C insnIndex:idx]];
                [fn registerValue:newRes];
                }
            if (insn.memoryResult)
                {
                XTIRValueId mid = [fn allocateValueId];
                newMem = [[XTIRValue alloc] initWithValueId:mid
                                                       type:memTy
                                                    defSite:[[XTIRDefSite alloc] initWithBlock:C insnIndex:idx]];
                [fn registerValue:newMem];
                }
            XTIRInsn* built = buildLike(insn, newRes, ops, newMem);
            BOOL readInBody = NO;
            if (rb)
                for (XTIRInsn* u in B.instructions)
                    for (XTIROperand* o in u.operands)
                        if (o.kind == XTIROperandKindUse && o.valueId == insn.result.valueId)
                            readInBody = YES;
            if (rb && !readInBody)
                [deferred addObject:built];
            else
                [C appendInstruction:built];
            if (insn.result)
                map[@(insn.result.valueId)] = @(newRes.valueId);
            if (insn.memoryResult)
                map[@(insn.memoryResult.valueId)] = @(newMem.valueId);
            if (insn == c.ivNext)
                cloneIvNext = newRes.valueId; // iv_{j+1}
            if (shareable)
                sharedPure[@(insn.result.valueId)] = @(newRes.valueId);
            idx++;
            }

        for (XTIRInsn* d in deferred)
            [C appendInstruction:d];
        // This copy's clone of each accumulator's update = acc_{j+1}.
        for (NSUInteger i = 0; i < nred; i++)
            {
            NSNumber* cn = map[@(((XTIRInsn*)c.redNexts[i]).result.valueId)];
            [accAfter[i] addObject:cn];
            prevRed[i] = cn;
            if (j + 1 == kUnrollFactor)
                lastRed[i] = cn;
            }

        // Intermediate copies guard `iv_{j+1} <cmp> bound` and fall through to
        // the next copy or out to E. The last copy takes the back-edge.
        if (j + 1 < kUnrollFactor && c.exactTrip)
            {
            // Provably true — no guard, the copy falls into the next one.
            [guardResults addObject:(XTIRValue*)[NSNull null]];
            }
        else if (j + 1 < kUnrollFactor)
            {
            NSMutableDictionary<NSNumber*, NSNumber*>* gmap = @{@(ivId) : @(cloneIvNext)}.mutableCopy;
            NSMutableArray<XTIROperand*>* gops = [NSMutableArray array];
            for (XTIROperand* op in c.guard.operands)
                [gops addObject:remapOp(op, gmap)];
            XTIRValueId grid = [fn allocateValueId];
            XTIRValue* gres = [[XTIRValue alloc] initWithValueId:grid
                                                            type:c.guard.result.type
                                                         defSite:[[XTIRDefSite alloc] initWithBlock:C insnIndex:idx]];
            [fn registerValue:gres];
            [C appendInstruction:buildLike(c.guard, gres, gops, nil)];
            [guardResults addObject:gres];
            }
        else
            {
            [guardResults addObject:(XTIRValue*)[NSNull null]];
            // Back-edge induction update, computed INDEPENDENTLY of the per-copy
            // increment chain: iv_next = iv_0 + N*step (iv_0 = the header phi),
            // rather than iv_{N-1}+step. The chain iv_1..iv_{N-1} still feeds the
            // copies' bodies, but the value carried across the back-edge no longer
            // waits for it — the loop's carried recurrence drops from N serial
            // adds to one (a Mul/Shl of the invariant step + one add; the Mul is
            // loop-invariant, off the carried path, and for power-of-two N folds
            // to a shifted-register add). cloneIvNext is now dead → DCE.
            XTIRType* ivTy = c.ivPhi.result.type;
            XTIROperand* nStepOp;
            if (c.stepIsConst)
                {
                nStepOp = [XTIROperand immIWithType:ivTy
                                              value:c.stepConstVal * (int64_t)kUnrollFactor];
                }
            else
                {
                XTIRValueId mid = [fn allocateValueId];
                XTIRValue* mres = [[XTIRValue alloc] initWithValueId:mid
                                                                type:ivTy
                                                             defSite:[[XTIRDefSite alloc] initWithBlock:C insnIndex:C.instructions.count]];
                [fn registerValue:mres];
                [C appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpMul
                                                               result:mres
                                                             operands:@[ c.step, [XTIROperand immIWithType:ivTy value:(int64_t)kUnrollFactor] ]
                                                               dbgLoc:nil]];
                nStepOp = [XTIROperand useWithValueId:mid];
                }
            XTIRValueId aid = [fn allocateValueId];
            XTIRValue* ares = [[XTIRValue alloc] initWithValueId:aid
                                                            type:ivTy
                                                         defSite:[[XTIRDefSite alloc] initWithBlock:C insnIndex:C.instructions.count]];
            [fn registerValue:ares];
            [C appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                           result:ares
                                                         operands:@[ [XTIROperand useWithValueId:ivId], nStepOp ]
                                                           dbgLoc:nil]];
            lastIvNext = aid;
            }
        prevIv = cloneIvNext;
        lastMap = map;
        [clones addObject:C];
        }

    // Wire terminators: intermediate copy → CondBranch(guard, next copy, E);
    // last copy → back-edge to H.
    for (NSUInteger j = 0; j < clones.count; j++)
        {
        if (j + 1 < clones.count)
            {
            XTIRValue* g = guardResults[j];
            if ((id)g == [NSNull null])
                {
                [clones[j] setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                                   result:nil
                                                                 operands:@[ [XTIROperand blockWithRef:clones[j + 1]] ]
                                                                   dbgLoc:nil]];
                continue;
                }
            XTIRInsn* cb = [[XTIRInsn alloc] initWithOpcode:XTIROpCondBranch
                                                     result:nil
                                                   operands:@[ [XTIROperand useWithValueId:g.valueId],
                                                               [XTIROperand blockWithRef:clones[j + 1]],
                                                               [XTIROperand blockWithRef:E] ]
                                                     dbgLoc:nil];
            [clones[j] setTerminator:cb];
            }
        else
            {
            [clones[j] setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                               result:nil
                                                             operands:@[ [XTIROperand blockWithRef:H] ]
                                                               dbgLoc:nil]];
            }
        }

    // Header iv phi: its body incoming (B, ivNext) becomes (lastClone, lastIvNext).
    NSMutableArray<XTIROperand*>* phiOps = [c.ivPhi.operands mutableCopy];
    for (NSUInteger k = 0; k + 1 < phiOps.count; k += 2)
        {
        if (phiOps[k].blockRef == B)
            {
            phiOps[k] = [XTIROperand blockWithRef:clones.lastObject];
            phiOps[k + 1] = [XTIROperand useWithValueId:lastIvNext];
            }
        }
    XTIRInsn* newPhi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                 result:c.ivPhi.result
                                               operands:phiOps
                                                 dbgLoc:c.ivPhi.dbgLoc];
    NSUInteger ivIdx = [H.phiNodes indexOfObjectIdenticalTo:c.ivPhi];
    if (ivIdx != NSNotFound)
        H.phiNodes[ivIdx] = newPhi;

    // Header reduction phis: body incoming (B, redNext) → (lastClone, lastRed[i]).
    for (NSUInteger i = 0; i < nred; i++)
        {
        XTIRInsn* rp = c.redPhis[i];
        NSMutableArray<XTIROperand*>* rops = [rp.operands mutableCopy];
        for (NSUInteger k = 0; k + 1 < rops.count; k += 2)
            {
            if (rops[k].blockRef == B)
                {
                rops[k] = [XTIROperand blockWithRef:clones.lastObject];
                rops[k + 1] = [XTIROperand useWithValueId:(XTIRValueId)[lastRed[i] unsignedLongLongValue]];
                }
            }
        XTIRInsn* newRp = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                    result:rp.result
                                                  operands:rops
                                                    dbgLoc:rp.dbgLoc];
        NSUInteger ri = [H.phiNodes indexOfObjectIdenticalTo:rp];
        if (ri != NSNotFound)
            H.phiNodes[ri] = newRp;
        }

    // Header guard branch: target B → first clone.
    XTIRInsn* t = H.terminator;
    NSMutableArray<XTIROperand*>* tops = [NSMutableArray arrayWithCapacity:t.operands.count];
    for (XTIROperand* op in t.operands)
        [tops addObject:(op.kind == XTIROperandKindBlock && op.blockRef == B)
                            ? [XTIROperand blockWithRef:clones.firstObject]
                            : op];
    XTIRInsn* nt = [[XTIRInsn alloc] initWithOpcode:t.opcode
                                             result:nil
                                           operands:tops
                                          predicate:t.predicate
                                             dbgLoc:t.dbgLoc];
    [H resetTerminator];
    [H setTerminator:nt];

    // Splice: drop B, insert the clones where it was.
    NSUInteger pos = [fn.blocks indexOfObjectIdenticalTo:B];
    [fn.blocks removeObjectIdenticalTo:B];
    if (pos == NSNotFound || pos > fn.blocks.count)
        pos = fn.blocks.count;
    [fn.blocks insertObjects:clones
                   atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(pos, clones.count)]];

        // Memory tokens defined in the body outlive it: B is spliced out, so a
        // post-loop Load/Store/Return still naming one would reference a value with
        // no definition (the printer spells it `%?36`). Point them at the LAST
        // copy's corresponding token — sound because this IR's memory model is
        // advisory (a token orders operations, it does not name storage), which is
        // the same reasoning the const-trip unroller's escape remap relies on.
        {
        NSMutableDictionary<NSNumber*, NSNumber*>* memRemap = [NSMutableDictionary dictionary];
        for (XTIRInsn* insn in B.instructions)
            if (insn.memoryResult)
                {
                NSNumber* to = lastMap[@(insn.memoryResult.valueId)];
                if (to)
                    memRemap[@(insn.memoryResult.valueId)] = to;
                }
        if (memRemap.count)
            {
            NSMutableSet<XTIRBlock*>* skip = [NSMutableSet setWithArray:clones];
            for (XTIRBlock* bb in fn.blocks)
                {
                if ([skip containsObject:bb])
                    continue;
                NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
                [all addObjectsFromArray:bb.phiNodes];
                [all addObjectsFromArray:bb.instructions];
                if (bb.terminator)
                    [all addObject:bb.terminator];
                for (XTIRInsn* insn in all)
                    {
                    NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
                    BOOL changed = NO;
                    for (NSUInteger k = 0; k < ops.count; k++)
                        if (ops[k].kind == XTIROperandKindUse)
                            {
                            NSNumber* r = memRemap[@(ops[k].valueId)];
                            if (r)
                                {
                                ops[k] = [XTIROperand useWithValueId:
                                                          (XTIRValueId)r.unsignedLongLongValue];
                                changed = YES;
                                }
                            }
                    if (changed)
                        [insn replaceOperands:ops];
                    }
                }
            }
        }

    // Exit phis for escaping accumulators. After unrolling, E is reached from H
    // (header guard false → 0 copies this group, carrying the header phi result)
    // and from each intermediate clone j (its guard false → copies 0..j ran,
    // carrying accAfter[i][j]); the last clone takes the back-edge and never
    // exits to E. recognise guaranteed E's only pre-unroll predecessor was H, so
    // these incomings cover every edge into E. Post-loop reads of the
    // accumulator (which previously read the header phi, now stale mid-group)
    // are rewritten to the exit phi.
    NSMutableArray<XTIRInsn*>* exitPhis = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, NSNumber*>* exitRemap = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < nred; i++)
        {
        if (![c.redEscapes[i] boolValue])
            continue;
        XTIRInsn* rp = c.redPhis[i];
        NSMutableArray<XTIROperand*>* eops = [NSMutableArray array];
        [eops addObject:[XTIROperand blockWithRef:H]];
        [eops addObject:[XTIROperand useWithValueId:(XTIRValueId)[c.redIds[i] unsignedLongLongValue]]];
        for (NSUInteger j = 0; j + 1 < clones.count; j++)
            {
            [eops addObject:[XTIROperand blockWithRef:clones[j]]];
            [eops addObject:[XTIROperand useWithValueId:(XTIRValueId)[accAfter[i][j] unsignedLongLongValue]]];
            }
        XTIRValueId eid = [fn allocateValueId];
        XTIRValue* eval = [[XTIRValue alloc] initWithValueId:eid
                                                        type:rp.result.type
                                                     defSite:[[XTIRDefSite alloc] initWithBlock:E insnIndex:0]];
        [fn registerValue:eval];
        XTIRInsn* ephi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                   result:eval
                                                 operands:eops
                                                   dbgLoc:nil];
        [E.phiNodes insertObject:ephi atIndex:0];
        [exitPhis addObject:ephi];
        exitRemap[c.redIds[i]] = @(eid);
        }
    if (exitRemap.count)
        {
        NSMutableSet<XTIRBlock*>* skip = [NSMutableSet setWithObject:H];
        [skip addObjectsFromArray:clones];
        for (XTIRBlock* bb in fn.blocks)
            {
            if ([skip containsObject:bb])
                continue;
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
            [all addObjectsFromArray:bb.phiNodes];
            [all addObjectsFromArray:bb.instructions];
            if (bb.terminator)
                [all addObject:bb.terminator];
            for (XTIRInsn* insn in all)
                {
                if ([exitPhis containsObject:insn])
                    continue; // don't rewrite the exit phi's own H-incoming
                BOOL changed = NO;
                NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
                for (NSUInteger k = 0; k < ops.count; k++)
                    {
                    if (ops[k].kind == XTIROperandKindUse)
                        {
                        NSNumber* r = exitRemap[@(ops[k].valueId)];
                        if (r)
                            {
                            ops[k] = [XTIROperand useWithValueId:(XTIRValueId)r.unsignedLongLongValue];
                            changed = YES;
                            }
                        }
                    }
                if (changed)
                    [insn replaceOperands:ops];
                }
            }
        }
    [self countGroups:c inFunction:fn clones:clones lastIvNext:lastIvNext];
    }

@end

// ── chain loops (#8) ────────────────────────────────────────────────────────

static BOOL ucUsesValue(XTIRInsn* n, XTIRValueId v)
    {
    for (XTIROperand* o in n.operands)
        if (o.kind == XTIROperandKindUse && o.valueId == v)
            return YES;
    return NO;
    }

// No memory access or call in the body, and no body value combines two vector
// phis' chains (a value's chain is the vector phi it derives from, if any).
static BOOL ucChainsIndependent(XTIRBlock* H, XTIRBlock* B)
    {
    NSMutableDictionary<NSNumber*, NSNumber*>* chainOf = [NSMutableDictionary dictionary];
    NSUInteger i = 0;
    for (XTIRInsn* p in H.phiNodes)
        {
        if (p.result && p.result.type.kind == XTIRTypeKindVec)
            chainOf[@(p.result.valueId)] = @(i);
        i++;
        }
    for (XTIRInsn* n in B.instructions)
        {
        if (n.memoryResult || isCallOpcode(n.opcode))
            return NO;
        NSNumber* ch = nil;
        for (XTIROperand* o in n.operands)
            {
            if (o.kind != XTIROperandKindUse)
                continue;
            NSNumber* oc = chainOf[@(o.valueId)];
            if (!oc)
                continue;
            if (ch && ch.unsignedIntegerValue != oc.unsignedIntegerValue)
                return NO;
            ch = oc;
            }
        if (ch && n.result)
            chainOf[@(n.result.valueId)] = ch;
        }
    return YES;
    }

@implementation XTIROptChainUnroll
    {
    XTIRInsn* _iv;
    XTIRInsn* _next;
    XTIRInsn* _cmp;
    XTIRBlock* _pre;   // for an odd trip, the block that runs one step first
    }

- (NSString*)passName
    {
    return @"unroll-chain-loops";
    }

- (NSInteger)minOptLevel
    {
    return 2;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (!prof.unrollsChainLoops)
        return YES;
    for (XTIRFunction* fn in mod.functions)
        for (XTIRBlock* L in [fn.blocks copy])
            if ([self recognise:L])
                {
                [self apply:L inFunction:fn];
                [self regroup:L body:L];
                }
    return YES;
    }

- (BOOL)recognise:(XTIRBlock*)L
    {
    XTIRInsn* t = L.terminator;
    if (!t || t.opcode != XTIROpCondBranch || t.operands.count < 3)
        return NO;
    if (t.operands[1].blockRef != L || t.operands[2].blockRef == L)
        return NO;
    if (t.operands[0].kind != XTIROperandKindUse)
        return NO;
    NSUInteger vecPhis = 0;
    _iv = nil;
    for (XTIRInsn* p in L.phiNodes)
        {
        if (!p.result || p.memoryResult || p.operands.count != 4)
            return NO;
        if (p.result.type.kind == XTIRTypeKindVec)
            vecPhis++;
        else if (!_iv && XTIRTypeKindIsInteger(p.result.type.kind))
            _iv = p;
        else
            return NO;
        }
    if (vecPhis < 2 || !_iv || L.instructions.count > 64)
        return NO;
    _next = nil;
    _cmp = nil;
    for (XTIRInsn* n in L.instructions)
        {
        if (n.result && n.result.valueId == t.operands[0].valueId)
            _cmp = n;
        if (n.opcode == XTIROpAdd && n.operands.count == 2 &&
            n.operands[0].kind == XTIROperandKindUse && n.operands[0].valueId == _iv.result.valueId &&
            n.operands[1].kind == XTIROperandKindImmI && n.operands[1].intValue == 1)
            _next = n;
        }
    if (!_next || !_cmp || _cmp.opcode != XTIROpICmp || _cmp.predicate != XTIRICmpULT || _cmp.operands.count < 2)
        return NO;
    XTIROperand *ca = _cmp.operands[0], *cb = _cmp.operands[1];
    if (ca.kind != XTIROperandKindUse || ca.valueId != _next.result.valueId || cb.kind != XTIROperandKindImmI)
        return NO;
    int64_t initK = -1;
    for (NSUInteger k = 0; k + 1 < _iv.operands.count; k += 2)
        {
        XTIROperand *bo = _iv.operands[k], *vo = _iv.operands[k + 1];
        if (bo.blockRef == L)
            {
            if (vo.kind != XTIROperandKindUse || vo.valueId != _next.result.valueId)
                return NO;
            }
        else if (vo.kind == XTIROperandKindImmI)
            initK = vo.intValue;
        }
    int64_t trip = (int64_t)(int32_t)cb.intValue - initK;
    if (initK < 0 || trip < 2)
        return NO;
    // An odd trip runs one step before the loop, in the block that enters it,
    // and the loop the rest, an even number. That block must do nothing but
    // enter. The port's ucRecognise.
    _pre = nil;
    if ((trip & 1) != 0)
        {
        if (trip < 3)
            return NO;
        for (NSUInteger k = 0; k + 1 < _iv.operands.count; k += 2)
            if (_iv.operands[k].blockRef != L)
                _pre = _iv.operands[k].blockRef;
        XTIRInsn* pt = _pre.terminator;
        if (!_pre || !pt || pt.opcode != XTIROpBranch || pt.operands.count != 1 || pt.operands[0].blockRef != L)
            return NO;
        }
    for (XTIRInsn* n in L.instructions)
        {
        if (n == _next || n == _cmp)
            continue;
        if (ucUsesValue(n, _iv.result.valueId) || ucUsesValue(n, _next.result.valueId) ||
            ucUsesValue(n, _cmp.result.valueId))
            return NO;
        }
    return ucChainsIndependent(L, L);
    }

// One step of the loop in the block before it: each instruction but the
// counter's, reading the phis' entry values, and the phis then start from that
// step's results (the counter from one on). The port's ucPeel.
- (void)peel:(XTIRBlock*)L inFunction:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIROperand*>* entry = [NSMutableDictionary dictionary];
    for (XTIRInsn* p in L.phiNodes)
        for (NSUInteger k = 0; k + 1 < p.operands.count; k += 2)
            if (p.operands[k].blockRef == _pre)
                entry[@(p.result.valueId)] = p.operands[k + 1];
    NSMutableDictionary<NSNumber*, NSNumber*>* step = [NSMutableDictionary dictionary];
    for (XTIRInsn* n in [L.instructions copy])
        {
        if (n == _next || n == _cmp)
            continue;
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:n.operands.count];
        for (XTIROperand* o in n.operands)
            {
            XTIROperand* use = o;
            if (o.kind == XTIROperandKindUse)
                {
                if (entry[@(o.valueId)])
                    use = entry[@(o.valueId)];
                else if (step[@(o.valueId)])
                    use = [XTIROperand useWithValueId:(XTIRValueId)step[@(o.valueId)].unsignedLongLongValue];
                }
            [ops addObject:use];
            }
        XTIRValue* r = nil;
        if (n.result)
            {
            XTIRValueId vid = [fn allocateValueId];
            r = [[XTIRValue alloc] initWithValueId:vid
                                              type:n.result.type
                                           defSite:[[XTIRDefSite alloc] initWithBlock:_pre insnIndex:_pre.instructions.count]];
            [fn registerValue:r];
            step[@(n.result.valueId)] = @(vid);
            }
        [_pre.instructions addObject:buildLike(n, r, ops, nil)];
        }
    for (XTIRInsn* p in L.phiNodes)
        {
        XTIROperand* back = nil;
        NSUInteger at = NSNotFound;
        for (NSUInteger k = 0; k + 1 < p.operands.count; k += 2)
            {
            if (p.operands[k].blockRef == L && p.operands[k + 1].kind == XTIROperandKindUse)
                back = p.operands[k + 1];
            if (p.operands[k].blockRef == _pre)
                at = k + 1;
            }
        if (at == NSNotFound)
            continue;
        NSMutableArray<XTIROperand*>* ops = [p.operands mutableCopy];
        if (p == _iv)
            ops[at] = [XTIROperand immIWithType:p.operands[at].type value:p.operands[at].intValue + 1];
        else if (back && step[@(back.valueId)])
            ops[at] = [XTIROperand useWithValueId:(XTIRValueId)step[@(back.valueId)].unsignedLongLongValue];
        else
            continue;
        [p replaceOperands:ops];
        }
    }

- (void)apply:(XTIRBlock*)L inFunction:(XTIRFunction*)fn
    {
    if (_pre)
        [self peel:L inFunction:fn];
    NSMutableDictionary<NSNumber*, NSNumber*>* map = [NSMutableDictionary dictionary];
    // Copy 1 reads copy 0's results where copy 0 read the phis.
    for (XTIRInsn* p in L.phiNodes)
        for (NSUInteger k = 0; k + 1 < p.operands.count; k += 2)
            if (p.operands[k].blockRef == L && p.operands[k + 1].kind == XTIROperandKindUse)
                map[@(p.result.valueId)] = @(p.operands[k + 1].valueId);
    NSUInteger n0 = L.instructions.count;
    for (NSUInteger i = 0; i < n0; i++)
        {
        XTIRInsn* n = L.instructions[i];
        if (n == _cmp)
            continue;
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:n.operands.count];
        for (XTIROperand* o in n.operands)
            [ops addObject:remapOp(o, map)];
        XTIRValue* r = nil;
        if (n.result)
            {
            XTIRValueId vid = [fn allocateValueId];
            r = [[XTIRValue alloc] initWithValueId:vid
                                              type:n.result.type
                                           defSite:[[XTIRDefSite alloc] initWithBlock:L insnIndex:L.instructions.count]];
            [fn registerValue:r];
            map[@(n.result.valueId)] = @(vid);
            }
        [L.instructions addObject:buildLike(n, r, ops, nil)];
        }
    // The compare tests copy 1's counter; the phis take copy 1's values.
    NSMutableArray<XTIROperand*>* cops = [_cmp.operands mutableCopy];
    cops[0] = [XTIROperand useWithValueId:(XTIRValueId)[map[@(_cmp.operands[0].valueId)] unsignedLongLongValue]];
    [_cmp replaceOperands:cops];
    [L.instructions removeObjectIdenticalTo:_cmp];
    [L.instructions addObject:_cmp];
    // The loop is rotated: what follows it reads the last step's values, which
    // are copy 1's now.
    NSMutableSet<NSNumber*>* phiIds = [NSMutableSet set];
    for (XTIRInsn* p in L.phiNodes)
        [phiIds addObject:@(p.result.valueId)];
    for (XTIRBlock* bb in fn.blocks)
        {
        if (bb == L)
            continue;
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* u in all)
            {
            BOOL changed = NO;
            NSMutableArray<XTIROperand*>* ops = [u.operands mutableCopy];
            for (NSUInteger k = 0; k < ops.count; k++)
                {
                XTIROperand* o = ops[k];
                if (o.kind != XTIROperandKindUse || [phiIds containsObject:@(o.valueId)])
                    continue;
                NSNumber* nv = map[@(o.valueId)];
                if (nv)
                    {
                    ops[k] = [XTIROperand useWithValueId:(XTIRValueId)nv.unsignedLongLongValue];
                    changed = YES;
                    }
                }
            if (changed)
                [u replaceOperands:ops];
            }
        }
    for (XTIRInsn* p in L.phiNodes)
        {
        BOOL changed = NO;
        NSMutableArray<XTIROperand*>* ops = [p.operands mutableCopy];
        for (NSUInteger k = 0; k + 1 < ops.count; k += 2)
            if (ops[k].blockRef == L && ops[k + 1].kind == XTIROperandKindUse && map[@(ops[k + 1].valueId)])
                {
                ops[k + 1] = [XTIROperand useWithValueId:(XTIRValueId)[map[@(ops[k + 1].valueId)] unsignedLongLongValue]];
                changed = YES;
                }
        if (changed)
            [p replaceOperands:ops];
        }
    }

// Chain by chain, each chain's instructions in their order; the instructions of
// no chain (the induction, the compare) first, which read no chain value.
- (void)regroup:(XTIRBlock*)H body:(XTIRBlock*)B
    {
    NSMutableDictionary<NSNumber*, NSNumber*>* chainOf = [NSMutableDictionary dictionary];
    NSUInteger nchains = 0;
    for (XTIRInsn* p in H.phiNodes)
        if (p.result && p.result.type.kind == XTIRTypeKindVec)
            chainOf[@(p.result.valueId)] = @(nchains++);
    NSMutableArray<NSNumber*>* chainOfInsn = [NSMutableArray array];
    for (XTIRInsn* n in B.instructions)
        {
        if (n.memoryResult)
            return;
        NSInteger ch = -1;
        for (XTIROperand* o in n.operands)
            {
            if (o.kind != XTIROperandKindUse)
                continue;
            NSNumber* oc = chainOf[@(o.valueId)];
            if (!oc)
                continue;
            if (ch >= 0 && ch != oc.integerValue)
                return;
            ch = oc.integerValue;
            }
        if (ch >= 0 && n.result)
            chainOf[@(n.result.valueId)] = @(ch);
        [chainOfInsn addObject:@(ch)];
        }
    NSMutableArray<XTIRInsn*>* order = [NSMutableArray array];
    for (NSUInteger i = 0; i < B.instructions.count; i++)
        if (chainOfInsn[i].integerValue < 0)
            [order addObject:B.instructions[i]];
    for (NSUInteger c = 0; c < nchains; c++)
        for (NSUInteger i = 0; i < B.instructions.count; i++)
            if (chainOfInsn[i].integerValue == (NSInteger)c)
                [order addObject:B.instructions[i]];
    if (order.count != B.instructions.count)
        return;
    [B.instructions setArray:order];
    }

@end
