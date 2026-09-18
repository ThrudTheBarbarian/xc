#import "XTIROptVectorize.h"

// ── THE LIMIT, AND THE WAY OUT (not yet implemented) ─────────────────────
//
// Every recogniser below bails on the same line:
//
//     if (vw < 2 || (N % (int64_t)vw) != 0) continue;
//
// so a loop vectorises only when its trip count is a compile-time CONSTANT and
// an exact multiple of the vector width. There is no epilogue anywhere in this
// pass, which means a constant 63 fails exactly as hard as a runtime `n` — and
// `for (i = 0; i < n; i++)` is the shape essentially all real code uses, and the
// only shape a library function CAN use. Measured cost, each compiler against
// its own platform's on the same machine, on a hoist-proof reduction+dot kernel:
// arm64 8.6x off clang -O3, x86-64 3.1x off gcc -O3. Fixture:
// tests/fixtures/vectorize_var_trip.xc.
//
// The cheap way out is NOT to clone the loop. `apply:` already builds the vector
// body into a SEPARATE `newBody` array and only then overwrites the scalar body
// (`[B.instructions setArray:newBody]`). So instead of mutating the loop in
// place and needing a scalar tail cloned from what was just destroyed:
//
//   1. emit `newBody` into a FRESH block B' with a fresh header H',
//   2. compute M = bound & ~(vw-1) in a new preheader — provably a multiple of
//      vw, so the existing "lands exactly on the bound" reasoning still holds,
//   3. run the vector loop to M, reduce the accumulator at its exit,
//   4. leave the ORIGINAL scalar loop completely untouched, and only re-point
//      its preheader phi incomings: iv 0 -> M, accumulator seed -> the reduced
//      vector value.
//
// The scalar loop is then the remainder by construction — no clone, no
// duplicated body, and the tail is the code that was already proven correct.
// A signed bound needs the `n <= 0` case to fall straight through to the scalar
// loop, which it already does (`i < n` is false at i = 0).

#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"

@interface XTVecCand : NSObject
@property(nonatomic) XTIRBlock *H, *B, *E;
@property(nonatomic) XTIRInsn *ivPhi, *ivNext, *guard;
@property(nonatomic) XTIRValueId ivId;
@property(nonatomic) XTIRType* laneType; // i32/u32
@property(nonatomic) NSUInteger vw;      // lanes per vector (4 for i32)
// Reduction candidates only (isReduction = YES). The loop carries a second
// (accumulator) phi whose back-edge value is `accNext = Add(acc, elem)`, where
// `elem` is an elementwise (iv-indexed) value. The map fields above still
// describe the induction variable.
@property(nonatomic) BOOL isReduction;
@property(nonatomic) XTIRInsn *accPhi, *accNext;
@property(nonatomic) XTIRValueId accId;   // accPhi result (the carry)
@property(nonatomic) XTIRValueId elemId;  // the per-lane value added each iter
@property(nonatomic) XTIROperand* seedOp; // accumulator's pre-loop value
// Epilogue: when the trip count is not an exact multiple of the vector width,
// the vector loop runs to `epiM` and a CLONE of the scalar loop finishes the
// tail. epiN is the original bound, kept for the clone's own guard.
@property(nonatomic) BOOL needsEpilogue;
@property(nonatomic) int64_t epiM;
@property(nonatomic) int64_t epiN;
// A RUNTIME trip count: the bound is not a literal, so the vector loop's limit
// M = n & ~(vw-1) is computed in the preheader and epiM is meaningless. The
// clone's induction phi is then seeded from that VALUE rather than an immediate.
@property(nonatomic) BOOL runtimeTrip;
@property(nonatomic) XTIROperand* boundOp;
// The iv's (constant) entry value. The runtime-trip limit M must be computed
// from the trip LENGTH (n - ivStart), not the bound: see xtvEmitRuntimeM.
@property(nonatomic) int64_t ivStart;
@property(nonatomic) XTIRBlock* preheader; // header pred that is not the latch
// Min/max reduction (isMaxMin = YES): the loop body is a diamond
//   body: load elem; cmp(elem,acc); CondBranch then, join
//   then: [reload elem]; Branch join
//   join: accNext = Phi[(body,acc),(then,elem)]; ivNext; Branch H
// B holds the diamond head (body); mmThen / mmLatch are the arm / join blocks.
@property(nonatomic) BOOL isMaxMin;
@property(nonatomic) BOOL isMax; // YES = max, NO = min
@property(nonatomic) XTIRBlock *mmThen, *mmLatch;
// Conditional-count reduction (isCount = YES): `for (i<N) if (a[i] <cmp> k) c += d`
// — an additive reduction whose per-iteration increment is masked by a compare.
// `accNext = Select(cmp, Add(acc, delta), acc)`. Vectorised as
// vacc += (VICmp(vload, splat k) & splat delta). B holds the Select; mmLatch
// holds the iv step.
@property(nonatomic) BOOL isCount;
@property(nonatomic) XTIRInsn* cmpInsn; // the per-lane ICmp(elem, k)
@property(nonatomic) XTIROperand* countDeltaOp;
// Widening sum (isWideningSum = YES): `acc:u32 += (u32)a[i]` over u8/u16 a[].
// The narrow load is vector-loaded (16×u8 / 8×u16) and folded into a 4×u32
// accumulator via uaddlp widening, then horizontally reduced.
@property(nonatomic) BOOL isWideningSum;
@property(nonatomic) XTIRType* loadLaneType; // u8 or u16
@property(nonatomic) XTIRValueId loadId;     // the narrow Load result
// Dot product (isDotProduct = YES): `acc:u32/i32 += (u32)(a[i]*b[i])` over two
// u8/u16 arrays. Both narrow loads are vector-loaded and multiplied in the narrow
// lane (VMul = pmullw/mul.8h keeps the low half, matching u16*u16 wrap), then the
// product vector is uaddlp-widened into the u32 accumulator and reduced. Reuses
// the widening-sum lowering with a VMul inserted before the widen.
@property(nonatomic) BOOL isDotProduct;
@property(nonatomic) XTIRValueId loadId2; // the second narrow Load result
@end
@implementation XTVecCand
@end

@implementation XTIROptVectorize

- (NSString*)passName
    {
    return @"vectorize";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

static BOOL elementwiseArith(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpAdd:
    case XTIROpSub:
    case XTIROpMul:
    case XTIROpAnd:
    case XTIROpOr:
    case XTIROpXor:
    case XTIROpFAdd:
    case XTIROpFSub:
    case XTIROpFMul: // float maps
        return YES;
    default:
        return NO;
        }
    }

// The vector opcode for a scalar elementwise op. Float ops reuse VAdd/VSub/VMul;
// the backend emits fadd/fsub/fmul when the result vector's lane is floating.
static XTIROpcode vectorOpFor(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpAdd:
    case XTIROpFAdd:
        return XTIROpVAdd;
    case XTIROpSub:
    case XTIROpFSub:
        return XTIROpVSub;
    case XTIROpMul:
    case XTIROpFMul:
        return XTIROpVMul;
    case XTIROpAnd:
        return XTIROpVAnd;
    case XTIROpOr:
        return XTIROpVOr;
    case XTIROpXor:
        return XTIROpVXor;
    default:
        return op;
        }
    }

// Lane types the map vectoriser handles: 8/16/32-bit integer (same-width
// wrapping arithmetic — 16×i8 / 8×i16 / 4×i32 per vector), or 32-bit float
// (float maps; float reductions need associativity the source doesn't grant).
static BOOL vectorisableLane(XTIRTypeKind k)
    {
    return k == XTIRTypeKindI8 || k == XTIRTypeKindU8 ||
           k == XTIRTypeKindI16 || k == XTIRTypeKindU16 ||
           k == XTIRTypeKindI32 || k == XTIRTypeKindU32 || k == XTIRTypeKindF32;
    }

static BOOL resolveConstInt(XTIROperand* op, NSDictionary<NSNumber*, XTIRInsn*>* defOf, int64_t* out)
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

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (!prof.vectorizesLoops)
        return YES;
    if (getenv("XTVEC_OFF"))
        return YES; // A/B measurement escape hatch
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn];
    return YES;
    }

// Split a loop that carries SEVERAL independent accumulators into one loop per
// accumulator, so the single-accumulator recognisers can take each in turn.
//
// Every recogniser here gates on the header carrying exactly two phis — the
// induction variable and one accumulator — so a loop like string_scan's
//
//     for (i) { if (buf[i] == 44) n++;  acc += (u32)buf[i]; }
//
// was refused outright, whatever its chains looked like. Rather than teach each
// recogniser to carry N accumulators, peel ONE accumulator into its own copy of
// the loop: runOnFunction iterates, so the copies come back round and are
// vectorised by the existing machinery. A loop with K accumulators peels K-1
// times and ends as K ordinary loops.
//
// Duplicating the loop duplicates its LOADS, which is why the body must be free
// of stores and calls — nothing here may be observed twice. The chains are
// otherwise independent by construction: each accumulator's cycle is closed
// (phi -> … -> accNext -> phi), so removing one pair takes its whole chain with
// it once the leftovers are swept.
- (BOOL)distributeAccumulators:(XTIRFunction*)fn
    {
    static int off = -1;
    if (off < 0) off = getenv("XTVEC_NO_DISTRIBUTE") ? 1 : 0;
    if (off) return NO;
    for (XTIRBlock* H in fn.blocks)
        {
        if (H.phiNodes.count < 3)
            continue;

        // The guard names the induction variable; everything else in the header
        // is an accumulator.
        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = nil;
        for (XTIRInsn* i in H.instructions)
            if (i.result && i.result.valueId == term.operands[0].valueId)
                guard = i;
        if (!guard || guard.opcode != XTIROpICmp || guard.operands.count < 2 ||
            guard.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRValueId ivId = guard.operands[0].valueId;

        // One body, one latch, one exit — the shape every recogniser assumes.
        XTIRBlock *B = nil, *E = nil;
        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        for (XTIRInsn* phi in H.phiNodes)
            if (phi.result && phi.result.valueId == ivId && phi.operands.count == 4)
                {
                XTIRBlock* latch = (phi.operands[0].blockRef == t0 || phi.operands[2].blockRef == t0) ? t0 : t1;
                B = latch;
                E = (latch == t0) ? t1 : t0;
                }
        if (!B || !E || B == H || E == H || B.phiNodes.count || E.phiNodes.count)
            continue;
        if (!B.terminator || B.terminator.opcode != XTIROpBranch ||
            B.terminator.operands.count < 1 || B.terminator.operands[0].blockRef != H)
            continue;

        // Nothing in the body may be observable twice.
        BOOL pure = YES;
        for (XTIRInsn* i in B.instructions)
            switch (i.opcode)
                {
            case XTIROpLoad: case XTIROpConst: case XTIROpAdd: case XTIROpSub:
            case XTIROpMul: case XTIROpAnd: case XTIROpOr: case XTIROpXor:
            case XTIROpShl: case XTIROpLShr: case XTIROpAShr: case XTIROpICmp:
            case XTIROpSelect: case XTIROpZExt: case XTIROpSExt: case XTIROpTrunc:
            case XTIROpAddrOf: case XTIROpFieldAddr: case XTIROpElementAddr:
                break;
            default:
                pure = NO;
                break;
                }
        if (!pure)
            continue;

        // The accumulators, paired with the body instruction that closes each
        // cycle. The peel target is the LAST of them.
        NSMutableArray<XTIRInsn*>* accPhis = [NSMutableArray array];
        NSMutableArray<XTIRInsn*>* accNexts = [NSMutableArray array];
        BOOL shaped = YES;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.result.valueId == ivId || phi.operands.count != 4)
                continue;
            XTIROperand* back = (phi.operands[0].blockRef == B) ? phi.operands[1] : phi.operands[3];
            if (back.kind != XTIROperandKindUse)
                { shaped = NO; break; }
            XTIRInsn* accNext = nil;
            for (XTIRInsn* i in B.instructions)
                if (i.result && i.result.valueId == back.valueId)
                    accNext = i;
            if (!accNext)
                { shaped = NO; break; }
            [accPhis addObject:phi];
            [accNexts addObject:accNext];
            }
        if (!shaped || accPhis.count < 2)
            continue;

        // The chains must be INDEPENDENT. `a2 = a2 + a1` in the body would have
        // a1's chain swept out from under it and a2 would then read a deleted
        // value — which is not a theoretical worry: before this test, building
        // the self-hosted compiler with distribution on produced a compiler
        // that read float literals wrong, and the corpus lost twenty fixtures.
        //
        // The test is on the backward CONE of each cycle-closing instruction:
        // no accumulator's cone may contain another accumulator's phi or its
        // closing instruction. Sharing pure work is fine and expected — both of
        // string_scan's chains read the same load, and the copy simply loads it
        // again — so counting uses is the wrong test. It rejects the count
        // chain, whose phi an if-converted body reads twice.
        NSMutableArray<NSMutableSet<NSNumber*>*>* cones = [NSMutableArray array];
        for (XTIRInsn* accNext in accNexts)
            {
            NSMutableSet<NSNumber*>* cone = [NSMutableSet set];
            NSMutableArray<XTIRInsn*>* work = [NSMutableArray arrayWithObject:accNext];
            [cone addObject:@(accNext.result.valueId)];
            while (work.count)
                {
                XTIRInsn* cur = work.lastObject;
                [work removeLastObject];
                for (XTIROperand* o in cur.operands)
                    {
                    if (o.kind != XTIROperandKindUse || [cone containsObject:@(o.valueId)])
                        continue;
                    [cone addObject:@(o.valueId)];
                    for (XTIRInsn* i in B.instructions)
                        if (i.result && i.result.valueId == o.valueId)
                            [work addObject:i];
                    }
                }
            [cones addObject:cone];
            }
        BOOL independent = YES;
        for (NSUInteger a = 0; a < cones.count && independent; a++)
            for (NSUInteger b2 = 0; b2 < accPhis.count; b2++)
                {
                if (a == b2)
                    continue;
                if ([cones[a] containsObject:@(accPhis[b2].result.valueId)] ||
                    [cones[a] containsObject:@(accNexts[b2].result.valueId)])
                    { independent = NO; break; }
                }
        if (!independent)
            continue;
        XTIRInsn* victim = accPhis.lastObject;

        // Copy the whole loop; the copy keeps the peeled accumulator and the
        // original keeps the rest.
        XTIRBlock *H2 = nil, *B2 = nil;
        NSMutableDictionary<NSNumber*, NSNumber*>* cmap = [NSMutableDictionary dictionary];
        xtvCloneLoop(fn, H, B, &H2, &B2, cmap);
        XTIRValueId victimCloneId = (XTIRValueId)cmap[@(victim.result.valueId)].unsignedLongLongValue;

        // The original exits into a fresh PREHEADER for the copy, which then
        // falls into it. Branching H straight at H2 would work, but every
        // recogniser refuses a loop whose exit block carries phis — and H2's
        // phis are exactly that — so the original would stop being vectorisable
        // the moment it was split. The empty block costs one branch and keeps
        // both halves in the shape the recognisers expect.
        XTIRBlock* PH2 = [[XTIRBlock alloc] init];
        PH2.name = [NSString stringWithFormat:@"%@_pre", H2.name ?: @"hdr"];
        [PH2 setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                     result:nil
                                                   operands:@[ [XTIROperand blockWithRef:H2] ]
                                                     dbgLoc:term.dbgLoc]];

        NSMutableArray<XTIROperand*>* tops = [term.operands mutableCopy];
        for (NSUInteger k = 0; k < tops.count; k++)
            if (tops[k].kind == XTIROperandKindBlock && tops[k].blockRef == E)
                tops[k] = [XTIROperand blockWithRef:PH2];
        [term replaceOperands:tops];

        // The copy is entered from that preheader now, not the original's. Its
        // seeds are unchanged: it runs the same range from the same starting
        // values.
        XTIRBlock* PH = (H.phiNodes.count && H.phiNodes[0].operands[0].blockRef == B)
                            ? H.phiNodes[0].operands[2].blockRef
                            : (H.phiNodes.count ? H.phiNodes[0].operands[0].blockRef : nil);
        for (XTIRInsn* phi in H2.phiNodes)
            {
            NSMutableArray<XTIROperand*>* pops = [phi.operands mutableCopy];
            for (NSUInteger k = 0; k + 1 < pops.count; k += 2)
                if (pops[k].kind == XTIROperandKindBlock && pops[k].blockRef == PH)
                    pops[k] = [XTIROperand blockWithRef:PH2];
            [phi replaceOperands:pops];
            }

        // After the loops, the peeled accumulator is the COPY's.
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
            [all addObjectsFromArray:bb.phiNodes];
            [all addObjectsFromArray:bb.instructions];
            if (bb.terminator) [all addObject:bb.terminator];
            for (XTIRInsn* i in all)
                {
                if (bb == H2 || bb == B2)
                    continue;
                NSMutableArray<XTIROperand*>* ops = [i.operands mutableCopy];
                BOOL hit = NO;
                for (NSUInteger k = 0; k < ops.count; k++)
                    if (ops[k].kind == XTIROperandKindUse && ops[k].valueId == victim.result.valueId)
                        { ops[k] = [XTIROperand useWithValueId:victimCloneId]; hit = YES; }
                if (hit) [i replaceOperands:ops];
                }
            }

        // The copy must be IN the function before anything is dropped: the sweep
        // in dropAccumulator decides what is dead by walking fn.blocks, so a
        // copy that is not yet listed contributes no uses and its whole body
        // scores dead.
        NSUInteger at = [fn.blocks indexOfObjectIdenticalTo:B];
        [fn.blocks insertObjects:@[ PH2, H2, B2 ]
                       atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(at + 1, 3)]];

        // Drop the peeled accumulator from the original, and the others from the
        // copy. Each is a closed cycle, so the phi and its back-edge definition
        // go together and the rest of the chain falls out in the sweep below.
        [self dropAccumulator:victim.result.valueId header:H body:B fn:fn];
        for (XTIRInsn* phi in [H2.phiNodes copy])
            {
            if (!phi.result || phi.result.valueId == victimCloneId)
                continue;
            XTIRValueId ivCloneId = (XTIRValueId)cmap[@(ivId)].unsignedLongLongValue;
            if (phi.result.valueId == ivCloneId)
                continue;
            [self dropAccumulator:phi.result.valueId header:H2 body:B2 fn:fn];
            }

        return YES;
        }
    return NO;
    }

// Remove one accumulator's phi and back-edge definition from a loop, then sweep
// whatever that orphans out of the body. The cycle is closed, so nothing else
// can be referring to either once the uses outside the loop have been rewritten.
- (void)dropAccumulator:(XTIRValueId)accId
                 header:(XTIRBlock*)H
                   body:(XTIRBlock*)B
                     fn:(XTIRFunction*)fn
    {
    XTIRValueId backId = 0;
    NSMutableArray<XTIRInsn*>* keptPhis = [NSMutableArray array];
    for (XTIRInsn* phi in H.phiNodes)
        {
        if (phi.result && phi.result.valueId == accId && phi.operands.count == 4)
            {
            XTIROperand* back = (phi.operands[0].blockRef == B) ? phi.operands[1] : phi.operands[3];
            if (back.kind == XTIROperandKindUse)
                backId = back.valueId;
            continue;
            }
        [keptPhis addObject:phi];
        }
    [H.phiNodes setArray:keptPhis];

    NSMutableArray<XTIRInsn*>* kept = [NSMutableArray array];
    for (XTIRInsn* i in B.instructions)
        if (!(i.result && i.result.valueId == backId))
            [kept addObject:i];
    [B.instructions setArray:kept];

    // Sweep the orphans: a pure body instruction nothing reads any more. To a
    // fixpoint, because removing one can orphan the one behind it.
    BOOL removed = YES;
    while (removed)
        {
        removed = NO;
        NSCountedSet<NSNumber*>* used = [NSCountedSet set];
        for (XTIRBlock* bb in fn.blocks)
            {
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
            [all addObjectsFromArray:bb.phiNodes];
            [all addObjectsFromArray:bb.instructions];
            if (bb.terminator) [all addObject:bb.terminator];
            for (XTIRInsn* i in all)
                for (XTIROperand* o in i.operands)
                    if (o.kind == XTIROperandKindUse)
                        [used addObject:@(o.valueId)];
            }
        NSMutableArray<XTIRInsn*>* keep = [NSMutableArray array];
        for (XTIRInsn* i in B.instructions)
            {
            BOOL dead = i.result && !i.memoryResult &&
                        [used countForObject:@(i.result.valueId)] == 0 &&
                        (i.opcode == XTIROpICmp || i.opcode == XTIROpSelect ||
                         i.opcode == XTIROpAdd || i.opcode == XTIROpSub ||
                         i.opcode == XTIROpMul || i.opcode == XTIROpAnd ||
                         i.opcode == XTIROpOr || i.opcode == XTIROpXor ||
                         i.opcode == XTIROpZExt || i.opcode == XTIROpSExt ||
                         i.opcode == XTIROpTrunc || i.opcode == XTIROpConst ||
                         i.opcode == XTIROpShl || i.opcode == XTIROpLShr ||
                         i.opcode == XTIROpAShr);
            if (dead) { removed = YES; continue; }
            [keep addObject:i];
            }
        [B.instructions setArray:keep];
        }
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    BOOL reduxOff = getenv("XTVEC_REDUX_OFF") != NULL;
    for (NSUInteger iter = 0; iter < 256; iter++)
        {
        XTVecCand* c = [self recognise:fn];
        if (c)
            {
            [self apply:c inFunction:fn];
            continue;
            }
        XTVecCand* r = reduxOff ? nil : [self recogniseReduction:fn];
        if (r)
            {
            [self applyReduction:r inFunction:fn];
            continue;
            }
        XTVecCand* m = reduxOff ? nil : [self recogniseMaxMin:fn];
        if (m)
            {
            [self applyMaxMin:m inFunction:fn];
            continue;
            }
        XTVecCand* cn = reduxOff ? nil : [self recogniseCountReduction:fn];
        if (cn)
            {
            [self applyCountReduction:cn inFunction:fn];
            continue;
            }
        XTVecCand* ws = reduxOff ? nil : [self recogniseWideningSum:fn];
        if (ws)
            {
            [self applyWideningSum:ws inFunction:fn];
            continue;
            }
        XTVecCand* dp = reduxOff ? nil : [self recogniseDotProduct:fn];
        // shares the widening-sum lowering
        if (dp)
            {
            [self applyWideningSum:dp inFunction:fn];
            continue;
            }
        // Nothing matched. If the loop carries several accumulators, peel one
        // into its own copy and come round again — the copies are ordinary
        // single-accumulator loops that the recognisers above already handle.
        if (!reduxOff && [self distributeAccumulators:fn])
            continue;
        break;
        }
    // Break the serial accumulator dependency: unroll vectorised reduction loops
    // with several independent accumulators (clang-style), so the OoO core
    // overlaps the add/max chains. Profile-gated; XTVEC_NOUNROLL disables.
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (prof.vectorizesLoops && !getenv("XTVEC_NOUNROLL"))
        [self unrollVectorReductionsInFunction:fn];
    }

// Does this induction phi provably start at ZERO on the loop's entry edge?
//
// EVERY recogniser needs this, and none of them had it. The transforms step the
// EXISTING induction phi by the vector width and keep the loop's guard, which
// reproduces the scalar loop only when the counter starts at 0. With a non-zero
// start the guard `i < N` is still tested, but the vector body reads and writes
// a whole vector at each step — so the iteration space is wrong at BOTH ends:
//
//   reduction:  for (i = 1; i < 64; i++) s += a[i];   returned 1956, not 2016
//   map:        for (i = 2; i < 16; i++) b[i] = ...;  wrote b[0] and b[1] too
//
// The map case is the more alarming one: it CLOBBERS memory before the range.
// Both were live at -O2 and above on arm64, x86-64 and arm9.
//
// `latch` is the block the back edge comes from, so the OTHER incoming operand
// is the entry value.
// SUPERSEDED by xtvIvStartConst below, which returns the start rather than
// only testing it for zero. A non-zero start is now VECTORISED rather than
// refused: the transforms step the existing phi by vw and keep the guard, so
// the loop covers whole vectors of [start, N) provided the arithmetic is done
// on the trip LENGTH (N - start) instead of the bound N. The reduction
// recogniser's epilogue already did exactly that and refused anyway.
//
// What must not happen is approximating: a start the pass cannot resolve to a
// non-negative constant is still refused, because the gate below reasons about
// a concrete iteration space.
static BOOL xtvIvStartConst(XTIRInsn* ivPhi, XTIRBlock* latch,
                            NSDictionary<NSNumber*, XTIRInsn*>* defOf,
                            int64_t* startOut)
    {
    if (!ivPhi || ivPhi.operands.count != 4)
        return NO;
    XTIROperand* entry = (ivPhi.operands[0].blockRef == latch)
                             ? ivPhi.operands[3]
                             : ivPhi.operands[1];
    int64_t start = 0;
    if (!entry || !resolveConstInt(entry, defOf, &start))
        return NO;
    if (start < 0)
        return NO;
    if (startOut)
        *startOut = start;
    return YES;
    }

- (nullable XTVecCand*)recognise:(XTIRFunction*)fn
    {
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

    for (XTIRBlock* H in fn.blocks)
        {
        if (H.phiNodes.count != 1)
            continue; // single induction; no reduction
        XTIRInsn* ivPhi = H.phiNodes[0];
        if (!ivPhi.result || ivPhi.memoryResult)
            continue;
        XTIRValueId ivId = ivPhi.result.valueId;

        // header pure (just the guard)
        BOOL hp = YES;
        for (XTIRInsn* insn in H.instructions)
            if (insn.memoryResult)
                {
                hp = NO;
                break;
                }
        if (!hp)
            continue;

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
        // guard: ICmp <ULT/SLT> i, N(const); i is the iv on the left.
        if (guard.operands[0].kind != XTIROperandKindUse || guard.operands[0].valueId != ivId)
            continue;
        int64_t N = 0;
        // A literal, or the RUNTIME bound handled below. Same rule as the
        // reduction: a runtime bound needs a strict `<` (with `i <= n` the trip
        // is n+1 and n & ~(vw-1) is wrong) and must be loop-invariant, which is
        // checked once the body block is known.
        BOOL constBound = resolveConstInt(guard.operands[1], defOf, &N);
        BOOL runtimeTrip = NO;
        if (!constBound)
            {
            if (guard.operands[1].kind != XTIROperandKindUse)
                continue;
            if (!(guard.predicate == XTIRICmpULT || guard.predicate == XTIRICmpSLT))
                continue;
            runtimeTrip = YES;
            }
        else if (N <= 0)
            continue;

        // body B latches to H unconditionally; E is the other target.
        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        BOOL (^latch)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b && b != H && b.phiNodes.count == 0 && b.terminator &&
                 b.terminator.opcode == XTIROpBranch && b.terminator.operands.count >= 1 &&
                 b.terminator.operands[0].blockRef == H;
        };
        XTIRBlock *B = nil, *E = nil;
        if (latch(t0))
            {
            B = t0;
            E = t1;
            }
        else if (latch(t1))
            {
            B = t1;
            E = t0;
            }
        else
            continue;
        if (!E || B.instructions.count == 0)
            continue;

        // ivNext = Add(i, 1), back-edge of the phi, used once.
        if (ivPhi.operands.count != 4)
            continue;
        XTIROperand* nextOp = (ivPhi.operands[0].blockRef == B)   ? ivPhi.operands[1]
                              : (ivPhi.operands[2].blockRef == B) ? ivPhi.operands[3]
                                                                  : nil;
        if (!nextOp || nextOp.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* ivNext = defOf[@(nextOp.valueId)];
        if (!ivNext || ivNext.opcode != XTIROpAdd || defBlk[@(nextOp.valueId)] != B)
            continue;
        if ([uses countForObject:@(nextOp.valueId)] != 1)
            continue;
        int64_t step = 0;
        XTIROperand* stepOp = nil;
        if (ivNext.operands[0].kind == XTIROperandKindUse && ivNext.operands[0].valueId == ivId)
            stepOp = ivNext.operands[1];
        else if (ivNext.operands[1].kind == XTIROperandKindUse && ivNext.operands[1].valueId == ivId)
            stepOp = ivNext.operands[0];
        if (!stepOp || !resolveConstInt(stepOp, defOf, &step) || step != 1)
            continue;

        // iv must not escape (used only in H/B); guard + ElementAddr indices + ivNext use it.
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            for (XTIRInsn* u in bb.instructions)
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == ivId)
                        {
                        hp = NO;
                        break;
                        }
            }
        if (!hp)
            continue;

        // Classify every body instruction. Allowed: AddrOf(Sym), ElementAddr
        // (invariant base, index == i), Load(EA), Store(EA,val), elementwise
        // int arith, Const, and the single ivNext. Anything else → bail. Gather
        // the lane type from the loads/stores (must be a consistent i32/u32).
        XTIRType* laneType = nil;
        BOOL ok = YES, sawLoad = NO, sawStore = NO;
        // The elementwise value set: results of iv-indexed loads and of
        // elementwise arith. An arith/store operand must be in this set, or a
        // loop-invariant constant (splattable). This rejects a per-lane-varying
        // scalar (e.g. `b[i]*i`, where `i` differs per lane) being broadcast.
        NSMutableSet<NSNumber*>* elemIds = [NSMutableSet set];
        BOOL (^isElemAddrAtIv)(XTIROperand*) = ^BOOL(XTIROperand* p) {
          if (p.kind != XTIROperandKindUse)
              return NO;
          XTIRInsn* ea = defOf[@(p.valueId)];
          if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count < 2)
              return NO;
          if (ea.operands[1].kind != XTIROperandKindUse || ea.operands[1].valueId != ivId)
              return NO;
          return YES;
        };
        // An operand usable in the elementwise computation: an elementwise value
        // (per-lane vector), or a loop-INVARIANT scalar (same for every lane, so
        // safely splattable) — a constant (possibly widened/narrowed), or a value
        // defined outside the loop. A per-lane-varying value (the iv, or anything
        // derived from it in the body) is neither, and is rejected.
        int64_t _k;
        BOOL (^elemOperandOK)(XTIROperand*) = ^BOOL(XTIROperand* o) {
          if (o.kind == XTIROperandKindImmI)
              return YES;
          if (o.kind != XTIROperandKindUse)
              return NO;
          if ([elemIds containsObject:@(o.valueId)])
              return YES;
          int64_t kk;
          if (resolveConstInt(o, defOf, &kk))
              return YES; // (widened) constant
          XTIRBlock* db = defBlk[@(o.valueId)];
          return db != nil && db != B && db != H; // loop-invariant
        };
        (void)_k;
        for (XTIRInsn* insn in B.instructions)
            {
            if (insn == ivNext)
                continue;
            XTIROpcode op = insn.opcode;
            if (op == XTIROpAddrOf)
                continue;
            if (op == XTIROpElementAddr)
                {
                // base loop-invariant (an AddrOf, or defined outside B); index == iv.
                if (insn.operands.count < 2 ||
                    insn.operands[1].kind != XTIROperandKindUse || insn.operands[1].valueId != ivId)
                    {
                    ok = NO;
                    break;
                    }
                XTIROperand* base = insn.operands[0];
                if (base.kind == XTIROperandKindUse && defBlk[@(base.valueId)] == B)
                    {
                    XTIRInsn* bd = defOf[@(base.valueId)];
                    if (!bd || bd.opcode != XTIROpAddrOf)
                        {
                        ok = NO;
                        break;
                        }
                    }
                continue;
                }
            if (op == XTIROpLoad)
                {
                if (insn.operands.count < 1 || !isElemAddrAtIv(insn.operands[0]) || !insn.result)
                    {
                    ok = NO;
                    break;
                    }
                XTIRType* lt = insn.result.type;
                if (!lt || !vectorisableLane(lt.kind))
                    {
                    ok = NO;
                    break;
                    }
                if (laneType && laneType.kind != lt.kind)
                    {
                    ok = NO;
                    break;
                    }
                laneType = lt;
                sawLoad = YES;
                [elemIds addObject:@(insn.result.valueId)];
                continue;
                }
            if (op == XTIROpStore)
                {
                if (insn.operands.count < 2 || !isElemAddrAtIv(insn.operands[0]) ||
                    !elemOperandOK(insn.operands[1]))
                    {
                    ok = NO;
                    break;
                    }
                sawStore = YES;
                continue;
                }
            // Scalar plumbing kept verbatim (constants, and the widen/narrow of
            // the step or invariant operands) — not part of the elementwise set.
            if (op == XTIROpConst || op == XTIROpZExt || op == XTIROpSExt ||
                op == XTIROpTrunc)
                continue;
            if (elementwiseArith(op))
                {
                if (!insn.result || !vectorisableLane(insn.result.type.kind))
                    {
                    ok = NO;
                    break;
                    }
                if (insn.operands.count < 2 ||
                    !elemOperandOK(insn.operands[0]) || !elemOperandOK(insn.operands[1]))
                    {
                    ok = NO;
                    break;
                    }
                [elemIds addObject:@(insn.result.valueId)];
                continue;
                }
            ok = NO;
            break; // call, shifted load, per-lane-varying scalar, etc.
            }
        if (!ok || !sawLoad || !sawStore || !laneType)
            continue;

        NSUInteger vw = 16 / laneType.byteWidth; // 4 for i32
        if (vw < 2)
            continue;
        // A non-zero start is VECTORISED, not refused: the epilogue below works
        // from the trip LENGTH, so [ivStart, N) splits into whole vectors plus a
        // scalar tail exactly as [0, N) does.
        //
        // The zero test used to double as what stopped the REMAINDER being
        // re-recognised and re-cloned — the clone's iv enters at M, so it failed
        // by construction. That job now belongs to the `< vw` test below, which
        // is the honest statement of it: a range with no whole vector in it is
        // not vectorisable, whatever it starts at.
        int64_t ivStart = 0;
        if (!xtvIvStartConst(ivPhi, B, defOf, &ivStart))
            continue;
        // N is only meaningful when the bound is a CONSTANT — with a runtime
        // trip it is still 0, so an unguarded `ivStart >= N` refuses every
        // runtime-bound loop, including the zero-start ones that vectorised
        // before. That is how this first showed up: the self-hosted optimiser
        // stopped vectorising vectorize_map_tail while the reference still did.
        if (!runtimeTrip && ivStart >= N)
            continue;
        // The header predecessor that is not the latch (same rule the reduction
        // recogniser uses; it spells this as a local `entryBlk` block).
        XTIRBlock* preheader = (ivPhi.operands[0].blockRef == B)
                                   ? ivPhi.operands[2].blockRef
                                   : ivPhi.operands[0].blockRef;
        if (!preheader || preheader == B || preheader == H)
            continue;

        // A trip that is not a whole number of vectors is still vectorisable:
        // the vector loop runs to the last whole vector and a CLONE of this loop
        // finishes the tail. The map case needs no VExit block — with no
        // accumulator to reduce, the only thing handed to the remainder is the
        // induction variable, and that is a constant (M). Mirrored in
        // selfhost/opt/Opt.xc.
        // A RUNTIME bound must be loop-INVARIANT: defined outside H and B, or
        // (a parameter) not defined by any instruction at all, so an absent
        // defBlk entry must NOT read as a refusal. It always takes the epilogue.
        if (runtimeTrip)
            {
            XTIRBlock* bdb = defBlk[@(guard.operands[1].valueId)];
            if (bdb == H || bdb == B)
                continue;
            }
        int64_t trip_ = N - ivStart;
        int64_t epiM_ = ivStart + (trip_ - (trip_ % (int64_t)vw));
        // Under one whole vector: stay scalar. Also what refuses the epilogue
        // CLONE, whose range is shorter than a vector by construction.
        if (!runtimeTrip && (epiM_ - ivStart) < (int64_t)vw)
            continue;

        XTVecCand* c = [XTVecCand new];
        c.H = H;
        c.B = B;
        c.E = E;
        c.ivPhi = ivPhi;
        c.ivNext = ivNext;
        c.guard = guard;
        c.ivId = ivId;
        c.laneType = laneType;
        c.vw = vw;
        c.preheader = preheader;
        c.epiN = N;
        c.epiM = epiM_;
        c.needsEpilogue = (runtimeTrip || epiM_ != N);
        c.runtimeTrip = runtimeTrip;
        c.boundOp = guard.operands[1];
        c.ivStart = ivStart;
        return c;
        }
    return nil;
    }

// ── Loop cloning, for the vector epilogue ────────────────────────────────
//
// Clone a single-body loop (header H with its phis, body B) into a fresh pair
// with all-new value ids, so the ORIGINAL can be vectorised in place while the
// clone survives as the scalar remainder. Modelled on XTIROptLoopUnroll's clone
// (same three constructor forms — callConv for calls, predicate for ICmp/FCmp,
// plain otherwise, because instructions are immutable and a rebuild must
// preserve their metadata), with one addition it does not need: the header's
// PHIS are cloned too, so phi operands need their BLOCK references remapped as
// well as their value ids.
//
// Returns the cloned header; `outMap` receives old value id -> new value id for
// every result the clone defines, so the caller can seed the clone's phi
// incomings (iv from the vector loop's end, accumulator from its reduction).
static XTIROperand* xtvRemapOperand(XTIROperand* op,
                                    NSDictionary<NSNumber*, NSNumber*>* vmap,
                                    NSDictionary<NSValue*, XTIRBlock*>* bmap)
    {
    if (op.kind == XTIROperandKindBlock)
        {
        XTIRBlock* nb = bmap[[NSValue valueWithNonretainedObject:op.blockRef]];
        return nb ? [XTIROperand blockWithRef:nb] : op;
        }
    if (op.kind != XTIROperandKindUse)
        return op;
    NSNumber* n = vmap[@(op.valueId)];
    return n ? [XTIROperand useWithValueId:(XTIRValueId)n.unsignedLongLongValue] : op;
    }

static XTIRInsn* xtvCloneInsn(XTIRInsn* insn, XTIRBlock* into, NSUInteger idx,
                              XTIRFunction* fn,
                              NSMutableDictionary<NSNumber*, NSNumber*>* vmap,
                              NSDictionary<NSValue*, XTIRBlock*>* bmap)
    {
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:insn.operands.count];
    for (XTIROperand* o in insn.operands)
        [ops addObject:xtvRemapOperand(o, vmap, bmap)];

    XTIRValue *res = nil, *mem = nil;
    if (insn.result)
        {
        XTIRValueId rid = [fn allocateValueId];
        res = [[XTIRValue alloc] initWithValueId:rid
                                            type:insn.result.type
                                         defSite:[[XTIRDefSite alloc] initWithBlock:into insnIndex:idx]];
        [fn registerValue:res];
        }
    if (insn.memoryResult)
        {
        XTIRValueId mid = [fn allocateValueId];
        mem = [[XTIRValue alloc] initWithValueId:mid
                                            type:[XTIRType memoryType]
                                         defSite:[[XTIRDefSite alloc] initWithBlock:into insnIndex:idx]];
        [fn registerValue:mem];
        }
    XTIRInsn* clone;
    if (insn.callConv)
        clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                          result:res
                                        operands:ops
                                        callConv:insn.callConv
                                          dbgLoc:insn.dbgLoc];
    else if (insn.opcode == XTIROpICmp || insn.opcode == XTIROpFCmp)
        clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                          result:res
                                        operands:ops
                                       predicate:insn.predicate
                                          dbgLoc:insn.dbgLoc];
    else
        clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                          result:res
                                        operands:ops
                                          dbgLoc:insn.dbgLoc];
    clone.memoryResult = mem;
    if (insn.result)
        vmap[@(insn.result.valueId)] = @(res.valueId);
    if (insn.memoryResult)
        vmap[@(insn.memoryResult.valueId)] = @(mem.valueId);
    return clone;
    }

// Clone a loop (header H with its phis + single body B) into a fresh pair with
// all-new value ids. `vmap` receives old id -> new id for everything the clone
// defines. Block references inside the clone are remapped H->H2, B->B2; any
// OTHER block reference (the preheader edge of a phi, the exit target of the
// terminator) is left pointing at the original, for the caller to re-point.
static void xtvCloneLoop(XTIRFunction* fn, XTIRBlock* H, XTIRBlock* B,
                         XTIRBlock** outH2, XTIRBlock** outB2,
                         NSMutableDictionary<NSNumber*, NSNumber*>* vmap)
    {
    XTIRBlock* H2 = [[XTIRBlock alloc] init];
    XTIRBlock* B2 = [[XTIRBlock alloc] init];
    H2.name = [NSString stringWithFormat:@"%@_rem", H.name ?: @"hdr"];
    B2.name = [NSString stringWithFormat:@"%@_rem", B.name ?: @"body"];

    NSDictionary<NSValue*, XTIRBlock*>* bmap = @{
        [NSValue valueWithNonretainedObject:H] : H2,
        [NSValue valueWithNonretainedObject:B] : B2,
    };

    // PHIS FIRST, and in two passes: a phi's operands may name values defined
    // later in the loop (the back-edge update), so the ids must all exist before
    // any operand is remapped. Pass 1 allocates the results; pass 2 fills in.
    NSMutableArray<XTIRInsn*>* phiClones = [NSMutableArray array];
    for (XTIRInsn* phi in H.phiNodes)
        {
        XTIRValueId rid = [fn allocateValueId];
        XTIRValue* res = [[XTIRValue alloc] initWithValueId:rid
                                                       type:phi.result.type
                                                    defSite:[[XTIRDefSite alloc] initWithBlock:H2 insnIndex:0]];
        [fn registerValue:res];
        vmap[@(phi.result.valueId)] = @(rid);
        [phiClones addObject:phi];
        }
    // Body next, so its results are in the map before the phis are filled.
    NSUInteger idx = 0;
    for (XTIRInsn* insn in B.instructions)
        [B2 appendInstruction:xtvCloneInsn(insn, B2, idx++, fn, vmap, bmap)];

    for (XTIRInsn* phi in phiClones)
        {
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        for (XTIROperand* o in phi.operands)
            [ops addObject:xtvRemapOperand(o, vmap, bmap)];
        XTIRValueId rid = (XTIRValueId)vmap[@(phi.result.valueId)].unsignedLongLongValue;
        XTIRValue* res = fn.values[@(rid)];
        [H2.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                         result:res
                                                       operands:ops
                                                         dbgLoc:phi.dbgLoc]];
        }
    // Header's own instructions (the guard), then the terminators.
    idx = 0;
    for (XTIRInsn* insn in H.instructions)
        [H2 appendInstruction:xtvCloneInsn(insn, H2, idx++, fn, vmap, bmap)];
    if (H.terminator)
        {
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        for (XTIROperand* o in H.terminator.operands)
            [ops addObject:xtvRemapOperand(o, vmap, bmap)];
        [H2 setTerminator:[[XTIRInsn alloc] initWithOpcode:H.terminator.opcode
                                                    result:nil
                                                  operands:ops
                                                    dbgLoc:H.terminator.dbgLoc]];
        }
    if (B.terminator)
        {
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        for (XTIROperand* o in B.terminator.operands)
            [ops addObject:xtvRemapOperand(o, vmap, bmap)];
        [B2 setTerminator:[[XTIRInsn alloc] initWithOpcode:B.terminator.opcode
                                                    result:nil
                                                  operands:ops
                                                    dbgLoc:B.terminator.dbgLoc]];
        }
    *outH2 = H2;
    *outB2 = B2;
    }

// ── Runtime vector limit ─────────────────────────────────────────────────
//
// M = ivStart + (max(n - ivStart, 0) & ~(vw-1)), emitted into the preheader.
// The old form, M = n & ~(vw-1), rounded the BOUND down instead of the trip
// length, which is only the same number when ivStart is 0 and n >= 0. It was
// wrong in two ways for `for (i = 2; i < n; i++)`:
//   - n below the start: the remainder phi seeds at M, and M = n & ~7 lands
//     BELOW ivStart — a [2, 1) loop (zero trips scalar) ran its remainder
//     from 0 and wrote a[0] (fuzz seed 267).
//   - a start that is not a multiple of vw: the iv steps ivStart + k*vw, so
//     it never equals n & ~7 and the last vector step overruns it — those
//     elements were then re-applied by the remainder ([2, 20), vw 8: vectors
//     cover 2..17 but M = 16, so 16 and 17 ran twice.
// Computing from the clamped trip length makes M exactly the iv's exit value
// on every path, so the remainder covers [M, n) and nothing else. The clamp
// is a sign-mask (AShr/Not/And) rather than a Select so it stays in the
// basic-ALU subset every vectorising back end already handles.
static XTIRValueId xtvEmitRuntimeM(XTIRFunction* fn, XTIRBlock* PH,
                                   XTIROperand* boundOp, int64_t ivStart,
                                   NSUInteger vw, XTIRType* ivTy)
    {
    XTIROperand* (^emit)(XTIROpcode, NSArray<XTIROperand*>*) =
        ^XTIROperand*(XTIROpcode op, NSArray<XTIROperand*>* ops) {
          XTIRValueId rid = [fn allocateValueId];
          XTIRValue* rv = [[XTIRValue alloc] initWithValueId:rid
                                                        type:ivTy
                                                     defSite:[[XTIRDefSite alloc] initWithBlock:PH insnIndex:0]];
          [fn registerValue:rv];
          [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:op
                                                               result:rv
                                                             operands:ops
                                                               dbgLoc:nil]];
          return [XTIROperand useWithValueId:rid];
        };
    XTIROperand* tl = boundOp;
    if (ivStart != 0)
        tl = emit(XTIROpSub, @[ boundOp,
                                [XTIROperand immIWithType:ivTy
                                                    value:ivStart] ]);
    // max(tl, 0): tl & ~(tl >> (bits-1)) — the sign fills the mask when tl is
    // negative, so the And zeroes it; a non-negative tl is left alone.
    XTIROperand* sgn = emit(XTIROpAShr,
                            @[ tl, [XTIROperand immIWithType:[XTIRType u8Type]
                                                       value:(int64_t)(ivTy.byteWidth * 8 - 1)] ]);
    XTIROperand* inv = emit(XTIROpNot, @[ sgn ]);
    XTIROperand* ctl = emit(XTIROpAnd, @[ tl, inv ]);
    XTIROperand* steps = emit(XTIROpAnd,
                              @[ ctl, [XTIROperand immIWithType:ivTy value:~((int64_t)vw - 1)] ]);
    XTIROperand* m = steps;
    if (ivStart != 0)
        m = emit(XTIROpAdd, @[ steps,
                               [XTIROperand immIWithType:ivTy
                                                   value:ivStart] ]);
    return m.valueId;
    }

- (void)apply:(XTVecCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock* B = c.B;
    XTIRType* vecTy = [XTIRType vecWithLane:c.laneType];

    // ── Epilogue, part 1: clone the scalar loop BEFORE anything below mutates
    // it. The vector transform overwrites B's instructions in place, so the
    // remainder has to be taken now or not at all.
    XTIRBlock *H2 = nil, *B2 = nil;
    XTIRValueId runtimeMId = 0; // the computed vector limit, when the trip is runtime
    NSMutableDictionary<NSNumber*, NSNumber*>* cmap = [NSMutableDictionary dictionary];
    if (c.needsEpilogue)
        {
        xtvCloneLoop(fn, c.H, B, &H2, &B2, cmap);
        // The vector loop now stops at the largest whole number of vectors; the
        // clone picks up from there and runs to the original bound (its own
        // guard, cloned, still tests against the original n).
        NSMutableArray<XTIROperand*>* gops = [c.guard.operands mutableCopy];
        if (c.runtimeTrip)
            {
            XTIRValueId mid = xtvEmitRuntimeM(fn, c.preheader, c.boundOp,
                                              c.ivStart, c.vw,
                                              c.ivPhi.result.type);
            runtimeMId = mid;
            gops[1] = [XTIROperand useWithValueId:mid];
            }
        else
            {
            gops[1] = [XTIROperand immIWithType:c.ivPhi.result.type value:c.epiM];
            }
        [c.guard replaceOperands:gops];
        }

    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                defOf[@(i.result.valueId)] = i;

    NSMutableArray<XTIRInsn*>* newBody = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, XTIRValue*>* vmap = [NSMutableDictionary dictionary];  // scalar id → vector value
    NSMutableDictionary<NSNumber*, XTIRValue*>* splat = [NSMutableDictionary dictionary]; // scalar id → splat vector

    // Block each value is defined in (for the entry-hoist invariance test below).
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                defBlk[@(i.result.valueId)] = bb;
    // Hoist invariant splats to the loop's PREHEADER, not the function entry.
    //
    // Entry was wrong, and dangerously so: the arm64 vector register pool is
    // v18..v31, every one of them CALLER-saved under AAPCS, and the allocator
    // has no call-clobber handling at all. A splat parked in the entry block
    // lives for the whole function, so any `bl` between it and the loop
    // destroys it -- the loop then adds whatever the callee left behind.
    // Reproduced as `gb[i] = ga[i] + 10` writing 112,115,118,121, where the
    // "splat" register held a vector of another array's data (#1134).
    //
    // The preheader keeps the compute-once property while making the range too
    // short to span a call -- and a vectorised loop body cannot itself contain a
    // call, since every recogniser rejects one, so entry-hoisted splats were the
    // only vector values that could ever cross one. applyCountReduction already
    // hoisted to the preheader; this brings the map applier into line. The
    // acceptance rules below are unchanged and remain sound: entry dominates the
    // preheader, so anything that dominated entry dominates it too.
    XTIRBlock* entry = c.preheader ?: fn.blocks.firstObject;
    NSMutableDictionary<NSString*, XTIRValue*>* entrySplatCache = [NSMutableDictionary dictionary];

    XTIRValue* (^newVecIn)(XTIRBlock*) = ^XTIRValue*(XTIRBlock* home) {
      XTIRValueId rid = [fn allocateValueId];
      XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                   type:vecTy
                                                defSite:[[XTIRDefSite alloc] initWithBlock:home insnIndex:0]];
      [fn registerValue:v];
      return v;
    };
    XTIRValue* (^newVec)(void) = ^XTIRValue* {
      return newVecIn(B);
    };

    // Hoist a LOOP-INVARIANT operand's VSplat to the function ENTRY block. Entry
    // dominates every loop — including any enclosing one — so the broadcast is
    // materialised ONCE on the way in instead of every iteration, and it stays
    // correct under nesting (unlike hoisting to a specific preheader, which is
    // what made the earlier general LICM-splat attempt miscompile nested loops).
    // A compile-time constant is rematerialised in entry; a param or an
    // entry-defined value is splatted in place. Returns nil when the operand
    // isn't provably entry-dominating, and the caller keeps the in-body splat.
    XTIROperand* (^entrySplat)(XTIROperand*) = ^XTIROperand*(XTIROperand* op) {
      if (!entry || entry == B || entry == c.H)
          return nil; // no distinct entry
      int64_t kv;
      BOOL isConst = resolveConstInt(op, defOf, &kv);
      NSString* ck = isConst ? [NSString stringWithFormat:@"c%lld", (long long)kv]
                             : (op.kind == XTIROperandKindUse ? [NSString stringWithFormat:@"v%llu",
                                                                                           (unsigned long long)op.valueId]
                                                              : nil);
      if (ck && entrySplatCache[ck])
          return [XTIROperand useWithValueId:entrySplatCache[ck].valueId];
      XTIROperand* scalar;
      if (isConst)
          {
          XTIRValue* cst = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                         type:c.laneType
                                                      defSite:[[XTIRDefSite alloc] initWithBlock:entry insnIndex:0]];
          [fn registerValue:cst];
          [entry.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                                  result:cst
                                                                operands:@[ [XTIROperand immIWithType:c.laneType value:kv] ]
                                                                  dbgLoc:nil]];
          scalar = [XTIROperand useWithValueId:cst.valueId];
          }
      else if (op.kind == XTIROperandKindUse)
          {
          // A param has no defining insn (available at entry); an entry-defined
          // value dominates the rest of entry. Anything defined mid-CFG can't be
          // referenced from entry — keep it in the body. A nil defBlk proves
          // NOTHING beyond "not defined when the map was built": defBlk is
          // computed once at pass entry, and a value CREATED by vectorising an
          // earlier loop (e.g. the new outer-loop phi carrying `rep`) is absent
          // from it. Treating absent as param hoisted a splat of a loop-carried
          // value to entry — it read the local's default 0 and the vectorised
          // loop silently dropped the addend. Only a REAL param may hoist on nil.
          XTIRBlock* db = defBlk[@(op.valueId)];
          if (db && db != entry)
              return nil;
          if (!db && op.valueId >= fn.paramTypes.count)
              return nil;
          scalar = op;
          }
      else
          {
          return nil;
          }
      XTIRValue* sp = newVecIn(entry);
      [entry.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                              result:sp
                                                            operands:@[ scalar ]
                                                              dbgLoc:nil]];
      if (ck)
          entrySplatCache[ck] = sp;
      return [XTIROperand useWithValueId:sp.valueId];
    };

    // The vector form of a scalar body operand: a previously-vectorised value, an
    // entry-hoisted broadcast of a loop-invariant scalar, or (fallback) a per-body
    // VSplat.
    XTIROperand* (^vecOperand)(XTIROperand*) = ^XTIROperand*(XTIROperand* op) {
      if (op.kind == XTIROperandKindUse)
          {
          XTIRValue* vv = vmap[@(op.valueId)];
          if (vv)
              return [XTIROperand useWithValueId:vv.valueId]; // elementwise (loop-varying)
          }
      XTIROperand* hoisted = entrySplat(op); // loop-invariant → splat once in entry
      if (hoisted)
          return hoisted;
      if (op.kind == XTIROperandKindUse)
          {
          XTIRValue* sp = splat[@(op.valueId)];
          if (!sp)
              {
              sp = newVec();
              [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                           result:sp
                                                         operands:@[ op ]
                                                           dbgLoc:nil]];
              splat[@(op.valueId)] = sp;
              }
          return [XTIROperand useWithValueId:sp.valueId];
          }
      // Immediate: materialise a splat from it directly.
      XTIRValue* sp = newVec();
      [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                   result:sp
                                                 operands:@[ op ]
                                                   dbgLoc:nil]];
      return [XTIROperand useWithValueId:sp.valueId];
    };

    for (XTIRInsn* insn in B.instructions)
        {
        if (insn == c.ivNext)
            {
            // Step the induction variable by the vector width.
            XTIROperand *a0 = insn.operands[0], *a1 = insn.operands[1];
            BOOL ivLeft = (a0.kind == XTIROperandKindUse && a0.valueId == c.ivId);
            XTIROperand* ivOp = ivLeft ? a0 : a1;
            XTIROperand* vwOp = [XTIROperand immIWithType:insn.result.type value:(int64_t)c.vw];
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                         result:insn.result
                                                       operands:@[ ivOp, vwOp ]
                                                         dbgLoc:insn.dbgLoc]];
            continue;
            }
        switch (insn.opcode)
            {
        case XTIROpAddrOf:
        case XTIROpElementAddr:
        case XTIROpConst:
        case XTIROpZExt:
        case XTIROpSExt:
        case XTIROpTrunc:
            [newBody addObject:insn]; // kept scalar (address / splat
                                      // source / dead step plumbing)
            break;
        case XTIROpLoad:
            {
            XTIRValue* vr = newVec();
            XTIRInsn* vl = [[XTIRInsn alloc] initWithOpcode:XTIROpVLoad
                                                     result:vr
                                                   operands:insn.operands
                                                     dbgLoc:insn.dbgLoc]; // [ea, mem]
            vl.memoryResult = insn.memoryResult;                          // preserve mem chain
            [newBody addObject:vl];
            vmap[@(insn.result.valueId)] = vr;
            break;
            }
        case XTIROpStore:
            {
            XTIROperand* vval = vecOperand(insn.operands[1]);
            NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
            ops[1] = vval;
            XTIRInsn* vs = [[XTIRInsn alloc] initWithOpcode:XTIROpVStore
                                                     result:nil
                                                   operands:ops
                                                     dbgLoc:insn.dbgLoc]; // [ea, vval, mem]
            vs.memoryResult = insn.memoryResult;
            [newBody addObject:vs];
            break;
            }
        // elementwise arith
        default:
            {
            XTIROperand* va = vecOperand(insn.operands[0]);
            XTIROperand* vb = vecOperand(insn.operands[1]);
            XTIRValue* vr = newVec();
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:vectorOpFor(insn.opcode)
                                                         result:vr
                                                       operands:@[ va, vb ]
                                                         dbgLoc:insn.dbgLoc]];
            vmap[@(insn.result.valueId)] = vr;
            break;
            }
            }
        }

    [B.instructions setArray:newBody];

    // ── Epilogue, part 2: the vector loop falls into the remainder instead of
    // the exit, through a LANDING PAD (VE) that does nothing but branch.
    //
    // The empty block is load-bearing, and the map case is where that shows.
    // Sending the vector loop straight to H2 looks right — a map carries
    // nothing out but the induction variable, which enters as the constant M —
    // and it works until LoopRotate gives the vector loop its SECOND exit (the
    // body's own back-edge test). That new edge then lands directly on a
    // phi-carrying header without an incoming for it, so the iv is undefined on
    // entry and the remainder is skipped: `for (i = 0; i < 5; i++) b[i] = ...`
    // wrote four elements and left the fifth untouched. Funnelling every vector
    // exit through one pred keeps H2's phis well-formed however the loop is
    // later reshaped. (The reduction epilogue gets this for free — its VE is
    // where the horizontal reduce lands.) Pinned by vectorize_map_tail.xc.
    if (c.needsEpilogue)
        {
        XTIRBlock *H = c.H, *E = c.E, *PH = c.preheader;
        XTIRBlock* VE = [[XTIRBlock alloc] init];
        VE.name = [NSString stringWithFormat:@"%@_vexit", H.name ?: @"hdr"];
        [VE setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                    result:nil
                                                  operands:@[ [XTIROperand blockWithRef:H2] ]
                                                    dbgLoc:nil]];

        NSMutableArray<XTIROperand*>* tops = [H.terminator.operands mutableCopy];
        for (NSUInteger k = 0; k < tops.count; k++)
            if (tops[k].kind == XTIROperandKindBlock && tops[k].blockRef == E)
                tops[k] = [XTIROperand blockWithRef:VE];
        [H.terminator replaceOperands:tops];

        // Seed the clone: its iv enters at M, on the edge from VE — which is
        // where the clone's phis still name the ORIGINAL preheader.
        XTIRValueId ivCloneId = (XTIRValueId)cmap[@(c.ivPhi.result.valueId)].unsignedLongLongValue;
        for (XTIRInsn* phi in H2.phiNodes)
            {
            NSMutableArray<XTIROperand*>* pops = [phi.operands mutableCopy];
            for (NSUInteger k = 0; k + 1 < pops.count; k += 2)
                {
                if (!(pops[k].kind == XTIROperandKindBlock && pops[k].blockRef == PH))
                    continue;
                pops[k] = [XTIROperand blockWithRef:VE];
                if (phi.result.valueId == ivCloneId)
                    pops[k + 1] = c.runtimeTrip
                                      ? [XTIROperand useWithValueId:runtimeMId]
                                      : [XTIROperand immIWithType:c.ivPhi.result.type value:c.epiM];
                }
            [phi replaceOperands:pops];
            }

        NSUInteger at = [fn.blocks indexOfObjectIdenticalTo:B];
        [fn.blocks insertObjects:@[ VE, H2, B2 ]
                       atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(at + 1, 3)]];
        }
    }

// ── Reduction recognition ────────────────────────────────────────────────
//
// Recognises `for (i=0; i<N; i++) acc += elem(a[i])` — a loop whose header
// carries the induction phi AND a single associative-add accumulator phi, with
// no store in the body. Shares the induction-variable / guard / latch shape
// with the map recogniser above; the extra structure is the accumulator phi
// `acc` whose back-edge value is `accNext = Add(acc, elem)`, where `elem` is an
// iv-indexed elementwise value (a load, or arith over loads / invariants).
- (nullable XTVecCand*)recogniseReduction:(XTIRFunction*)fn
    {
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

    for (XTIRBlock* H in fn.blocks)
        {
        if (H.phiNodes.count != 2)
            continue; // induction + accumulator

        // header pure (just the guard)
        BOOL hp = YES;
        for (XTIRInsn* insn in H.instructions)
            if (insn.memoryResult)
                {
                hp = NO;
                break;
                }
        if (!hp)
            continue;

        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || defBlk[@(term.operands[0].valueId)] != H)
            continue;
        if (guard.operands.count < 2 || guard.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRValueId ivId = guard.operands[0].valueId;
        // the guarded value must be one of the header phis (the induction var);
        // the other phi is the accumulator.
        XTIRInsn *ivPhi = nil, *accPhi = nil;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.memoryResult)
                {
                ivPhi = nil;
                break;
                }
            if (phi.result.valueId == ivId)
                ivPhi = phi;
            else
                accPhi = phi;
            }
        if (!ivPhi || !accPhi)
            continue;
        XTIRValueId accId = accPhi.result.valueId;
        // The bound may be a literal or a RUNTIME value. A runtime bound is
        // accepted only when loop-INVARIANT (checked below, once the body block
        // is known) and the guard is a STRICT less-than: with `i <= n` the trip
        // count is n+1 and the vector limit n & ~(vw-1) is simply wrong. The
        // constant path is left exactly as it was -- it has always assumed `<`
        // without checking, and tightening it here would alter accepted loops.
        int64_t N = 0;
        BOOL constBound = resolveConstInt(guard.operands[1], defOf, &N);
        BOOL runtimeTrip = NO;
        if (!constBound)
            {
            if (guard.operands[1].kind != XTIROperandKindUse)
                continue;
            if (!(guard.predicate == XTIRICmpULT || guard.predicate == XTIRICmpSLT))
                continue;
            runtimeTrip = YES;
            }
        else if (N <= 0)
            continue;

        // body B latches to H unconditionally; E is the other target.
        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        BOOL (^latch)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b && b != H && b.phiNodes.count == 0 && b.terminator &&
                 b.terminator.opcode == XTIROpBranch && b.terminator.operands.count >= 1 &&
                 b.terminator.operands[0].blockRef == H;
        };
        XTIRBlock *B = nil, *E = nil;
        if (latch(t0))
            {
            B = t0;
            E = t1;
            }
        else if (latch(t1))
            {
            B = t1;
            E = t0;
            }
        else
            continue;
        if (!E || B.instructions.count == 0)
            continue;
        // The horizontal reduce is inserted at the top of E; if E carried a phi
        // referencing the accumulator on the H→E edge, rewiring it to the reduce
        // result (defined later in E) would be invalid SSA. Bail on exit phis.
        if (E.phiNodes.count != 0)
            continue;

        // ivNext = Add(i, 1), back-edge of the iv phi, used once.
        if (ivPhi.operands.count != 4 || accPhi.operands.count != 4)
            continue;
        XTIROperand* (^backOp)(XTIRInsn*) = ^XTIROperand*(XTIRInsn* phi) {
          return (phi.operands[0].blockRef == B)   ? phi.operands[1]
                 : (phi.operands[2].blockRef == B) ? phi.operands[3]
                                                   : nil;
        };
        // The VALUE paired with the entry (non-latch) block: operands are
        // (block, value) pairs, so the entry value is index 3 when B is the
        // first pair, else index 1.
        XTIROperand* (^entryOp)(XTIRInsn*) = ^XTIROperand*(XTIRInsn* phi) {
          return (phi.operands[0].blockRef == B) ? phi.operands[3] : phi.operands[1];
        };
        XTIRBlock* (^entryBlk)(XTIRInsn*) = ^XTIRBlock*(XTIRInsn* phi) {
          return (phi.operands[0].blockRef == B) ? phi.operands[2].blockRef : phi.operands[0].blockRef;
        };
        XTIROperand* nextOp = backOp(ivPhi);
        if (!nextOp || nextOp.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* ivNext = defOf[@(nextOp.valueId)];
        if (!ivNext || ivNext.opcode != XTIROpAdd || defBlk[@(nextOp.valueId)] != B)
            continue;
        if ([uses countForObject:@(nextOp.valueId)] != 1)
            continue;
        int64_t step = 0;
        XTIROperand* stepOp = nil;
        if (ivNext.operands[0].kind == XTIROperandKindUse && ivNext.operands[0].valueId == ivId)
            stepOp = ivNext.operands[1];
        else if (ivNext.operands[1].kind == XTIROperandKindUse && ivNext.operands[1].valueId == ivId)
            stepOp = ivNext.operands[0];
        if (!stepOp || !resolveConstInt(stepOp, defOf, &step) || step != 1)
            continue;

        // accNext = back-edge value of the accumulator phi: Add(acc, elem),
        // defined in B and used exactly once (by the phi).
        XTIROperand* accNextOp = backOp(accPhi);
        if (!accNextOp || accNextOp.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* accNext = defOf[@(accNextOp.valueId)];
        if (!accNext || accNext.opcode != XTIROpAdd || defBlk[@(accNextOp.valueId)] != B)
            continue;
        if ([uses countForObject:@(accNextOp.valueId)] != 1)
            continue;
        XTIROperand* elemOp = nil;
        if (accNext.operands[0].kind == XTIROperandKindUse && accNext.operands[0].valueId == accId)
            elemOp = accNext.operands[1];
        else if (accNext.operands[1].kind == XTIROperandKindUse && accNext.operands[1].valueId == accId)
            elemOp = accNext.operands[0];
        if (!elemOp || elemOp.kind != XTIROperandKindUse)
            continue;
        XTIROperand* initOp = entryOp(accPhi);
        XTIRBlock* preheader = entryBlk(accPhi);
        if (!initOp || !preheader || preheader == B || preheader == H)
            continue;

        // The carry (accId) must be used inside the loop ONLY by accNext; the
        // induction var (ivId) must not escape H/B (guard + index + ivNext).
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            for (XTIRInsn* u in bb.instructions)
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == ivId)
                        {
                        hp = NO;
                        break;
                        }
            }
        if (!hp)
            continue;
        BOOL accClean = YES;
        for (XTIRBlock* bb in @[ H, B ])
            {
            for (XTIRInsn* u in bb.instructions)
                {
                if (u == accNext)
                    continue;
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == accId)
                        {
                        accClean = NO;
                        break;
                        }
                if (!accClean)
                    break;
                }
            if (!accClean)
                break;
            }
        if (!accClean)
            continue;

        // Classify the body's elementwise computation (no store; the reduce is
        // the output). Same allowed set as the map path, minus Store, plus the
        // ivNext / accNext we handle specially.
        XTIRType* laneType = nil;
        BOOL ok = YES, sawLoad = NO;
        NSMutableSet<NSNumber*>* elemIds = [NSMutableSet set];
        BOOL (^isElemAddrAtIv)(XTIROperand*) = ^BOOL(XTIROperand* p) {
          if (p.kind != XTIROperandKindUse)
              return NO;
          XTIRInsn* ea = defOf[@(p.valueId)];
          if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count < 2)
              return NO;
          if (ea.operands[1].kind != XTIROperandKindUse || ea.operands[1].valueId != ivId)
              return NO;
          return YES;
        };
        BOOL (^elemOperandOK)(XTIROperand*) = ^BOOL(XTIROperand* o) {
          if (o.kind == XTIROperandKindImmI)
              return YES;
          if (o.kind != XTIROperandKindUse)
              return NO;
          if ([elemIds containsObject:@(o.valueId)])
              return YES;
          int64_t kk;
          if (resolveConstInt(o, defOf, &kk))
              return YES;
          XTIRBlock* db = defBlk[@(o.valueId)];
          return db != nil && db != B && db != H;
        };
        for (XTIRInsn* insn in B.instructions)
            {
            if (insn == ivNext || insn == accNext)
                continue;
            XTIROpcode op = insn.opcode;
            if (op == XTIROpAddrOf)
                continue;
            if (op == XTIROpElementAddr)
                {
                if (insn.operands.count < 2 ||
                    insn.operands[1].kind != XTIROperandKindUse || insn.operands[1].valueId != ivId)
                    {
                    ok = NO;
                    break;
                    }
                XTIROperand* base = insn.operands[0];
                if (base.kind == XTIROperandKindUse && defBlk[@(base.valueId)] == B)
                    {
                    XTIRInsn* bd = defOf[@(base.valueId)];
                    if (!bd || bd.opcode != XTIROpAddrOf)
                        {
                        ok = NO;
                        break;
                        }
                    }
                continue;
                }
            if (op == XTIROpLoad)
                {
                if (insn.operands.count < 1 || !isElemAddrAtIv(insn.operands[0]) || !insn.result)
                    {
                    ok = NO;
                    break;
                    }
                XTIRType* lt = insn.result.type;
                if (!lt || !(lt.kind == XTIRTypeKindI32 || lt.kind == XTIRTypeKindU32))
                    {
                    ok = NO;
                    break;
                    }
                if (laneType && laneType.kind != lt.kind)
                    {
                    ok = NO;
                    break;
                    }
                laneType = lt;
                sawLoad = YES;
                [elemIds addObject:@(insn.result.valueId)];
                continue;
                }
            if (op == XTIROpConst || op == XTIROpZExt || op == XTIROpSExt || op == XTIROpTrunc)
                continue;
            if (elementwiseArith(op))
                {
                if (!insn.result || !(insn.result.type.kind == XTIRTypeKindI32 ||
                                      insn.result.type.kind == XTIRTypeKindU32))
                    {
                    ok = NO;
                    break;
                    }
                if (insn.operands.count < 2 ||
                    !elemOperandOK(insn.operands[0]) || !elemOperandOK(insn.operands[1]))
                    {
                    ok = NO;
                    break;
                    }
                [elemIds addObject:@(insn.result.valueId)];
                continue;
                }
            ok = NO;
            break; // Store, call, per-lane-varying scalar, etc.
            }
        if (!ok || !sawLoad || !laneType)
            continue;
        // The reduced element must itself be an elementwise (per-lane) value —
        // not a loop-invariant (that would be `acc += k`, a scaled count, not a
        // lane-wise reduction).
        if (![elemIds containsObject:@(elemOp.valueId)])
            continue;
        // The accumulator lane type must match the loads (i32/u32 add).
        if (!(accNext.result.type.kind == XTIRTypeKindI32 ||
              accNext.result.type.kind == XTIRTypeKindU32))
            continue;
        if (accNext.result.type.kind != laneType.kind)
            continue;

        NSUInteger vw = 16 / laneType.byteWidth; // 4 for i32
        if (vw < 2)
            continue;

        // The induction variable's START matters, and nothing used to check it.
        // The guard gives the BOUND, not the trip count: a loop from S runs
        // N - S times, and stepping by vw from S lands exactly on N only when
        // (N - S) is a whole number of vectors. With the old `N % vw` test a
        // loop like `for (i = 1; i < 64; i++)` was accepted — 64 % 4 == 0 —
        // while its real trip is 63, so the last vector read one element PAST
        // the array. Requiring a known S fixes that and is also what stops the
        // remainder loop below from being re-recognised as if it started at 0
        // (it starts at M, and re-analysing it re-clones it, without bound).
        XTIROperand* ivInitOp = entryOp(ivPhi);
        int64_t ivStart = 0;
        if (!ivInitOp || !resolveConstInt(ivInitOp, defOf, &ivStart))
            continue;
        if (!runtimeTrip && N <= ivStart)
            continue;
        // A NON-ZERO start is refused outright, and this is a BUG FIX, not a
        // conservative choice. The transform steps the existing iv phi by vw and
        // keeps the guard, which is only equivalent to the scalar loop when the
        // counter begins at 0; with `for (i = 1; i < 64; i++)` it produced a
        // WRONG ANSWER (1956 for a sum that is 2016) at -O2 and above, on every
        // vectorising back end, and had done so before this epilogue existed:
        // XTVEC_REDUX_OFF=1 gives the right answer, redux on gives 1956.
        // tests/fixtures/vectorize_const_tail.xc pins both shapes. Supporting a
        // non-zero start means rebasing the vector iv to 0, which is a separate
        // change; until then these loops stay scalar and CORRECT.
        // A non-zero start needs NOTHING here: the epilogue below is already
        // computed from the trip length (`trip_ = N - ivStart`), so it splits
        // [ivStart, N) into whole vectors plus a scalar tail. The refusal that
        // stood here was obsolete the moment that epilogue landed — verified by
        // lifting it: `for (i = 1; i < 64; i++) s += a[i]` gives 2016 and emits
        // NEON, where refusing gave 2016 scalar and no vector ops at all.

        // A trip that is not a whole number of vectors is still vectorisable:
        // the vector loop runs to the last whole vector and a CLONE of this loop
        // finishes the tail (xtvCloneLoop + the wiring in applyReduction).
        // Mirrored in selfhost/opt/Opt.xc.
        // A RUNTIME bound always takes the epilogue: how many whole vectors fit
        // is not knowable here, so the limit is computed in the preheader and
        // the clone runs [M, n). No separate `n < vw` guard is needed -- that
        // case gives M = 0, the vector loop's own guard fails at once, and the
        // clone runs the whole range from 0, the scalar loop unchanged. The
        // bound must be loop-INVARIANT: a value with NO defining instruction is
        // a parameter, invariant by construction, so an absent defBlk entry
        // must not read as a refusal.
        if (runtimeTrip)
            {
            XTIRBlock* bdb = defBlk[@(guard.operands[1].valueId)];
            if (bdb == H || bdb == B)
                continue;
            }
        int64_t trip_ = N - ivStart;
        int64_t epiM_ = ivStart + (trip_ - (trip_ % (int64_t)vw));
        if (!runtimeTrip && epiM_ != N && (epiM_ - ivStart) < (int64_t)vw)
            continue;

        XTVecCand* c = [XTVecCand new];
        c.H = H;
        c.B = B;
        c.E = E;
        c.ivPhi = ivPhi;
        c.ivNext = ivNext;
        c.guard = guard;
        c.ivId = ivId;
        c.laneType = laneType;
        c.vw = vw;
        c.isReduction = YES;
        c.accPhi = accPhi;
        c.accNext = accNext;
        c.accId = accId;
        c.elemId = elemOp.valueId;
        c.seedOp = initOp;
        c.preheader = preheader;
        c.epiN = N;
        c.epiM = epiM_;
        c.needsEpilogue = (runtimeTrip || epiM_ != N);
        c.runtimeTrip = runtimeTrip;
        c.boundOp = guard.operands[1];
        c.ivStart = ivStart;
        return c;
        }
    return nil;
    }

- (void)applyReduction:(XTVecCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock *B = c.B, *H = c.H, *E = c.E, *PH = c.preheader;

    // ── Epilogue, part 1: clone the scalar loop BEFORE anything below mutates
    // it. The vector transform overwrites B's instructions in place and rewrites
    // H's phis, so the remainder has to be taken now or not at all.
    XTIRBlock *H2 = nil, *B2 = nil;
    NSMutableDictionary<NSNumber*, NSNumber*>* cmap = [NSMutableDictionary dictionary];
    XTIRValueId runtimeMId = 0; // the computed vector limit, when the trip is runtime
    if (c.needsEpilogue)
        {
        xtvCloneLoop(fn, H, B, &H2, &B2, cmap);
        // The vector loop now stops at the largest whole number of vectors; the
        // clone picks up from there and runs to the original bound (its own
        // guard, cloned, still tests against the original n).
        NSMutableArray<XTIROperand*>* gops = [c.guard.operands mutableCopy];
        if (c.runtimeTrip)
            {
            XTIRValueId mid = xtvEmitRuntimeM(fn, PH, c.boundOp, c.ivStart,
                                              c.vw, c.ivPhi.result.type);
            runtimeMId = mid;
            gops[1] = [XTIROperand useWithValueId:mid];
            }
        else
            {
            gops[1] = [XTIROperand immIWithType:c.ivPhi.result.type value:c.epiM];
            }
        [c.guard replaceOperands:gops];
        }
    XTIRType* vecTy = [XTIRType vecWithLane:c.laneType];

    XTIRValue* (^newVal)(XTIRType*) = ^XTIRValue*(XTIRType* ty) {
      XTIRValueId rid = [fn allocateValueId];
      XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                   type:ty
                                                defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:0]];
      [fn registerValue:v];
      return v;
    };

    NSMutableArray<XTIRInsn*>* newBody = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, XTIRValue*>* vmap = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRValue*>* splat = [NSMutableDictionary dictionary];

    XTIROperand* (^vecOperand)(XTIROperand*) = ^XTIROperand*(XTIROperand* op) {
      if (op.kind == XTIROperandKindUse)
          {
          XTIRValue* vv = vmap[@(op.valueId)];
          if (vv)
              return [XTIROperand useWithValueId:vv.valueId];
          XTIRValue* sp = splat[@(op.valueId)];
          if (!sp)
              {
              sp = newVal(vecTy);
              [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                           result:sp
                                                         operands:@[ op ]
                                                           dbgLoc:nil]];
              splat[@(op.valueId)] = sp;
              }
          return [XTIROperand useWithValueId:sp.valueId];
          }
      XTIRValue* sp = newVal(vecTy);
      [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                   result:sp
                                                 operands:@[ op ]
                                                   dbgLoc:nil]];
      return [XTIROperand useWithValueId:sp.valueId];
    };

    // The vector accumulator phi (created below) — its result id is needed when
    // the body's VAdd consumes it.
    XTIRValue* vacc = newVal(vecTy);

    for (XTIRInsn* insn in B.instructions)
        {
        // step iv by the vector width
        if (insn == c.ivNext)
            {
            XTIROperand *a0 = insn.operands[0], *a1 = insn.operands[1];
            BOOL ivLeft = (a0.kind == XTIROperandKindUse && a0.valueId == c.ivId);
            XTIROperand* ivOp = ivLeft ? a0 : a1;
            XTIROperand* vwOp = [XTIROperand immIWithType:insn.result.type value:(int64_t)c.vw];
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                         result:insn.result
                                                       operands:@[ ivOp, vwOp ]
                                                         dbgLoc:insn.dbgLoc]];
            continue;
            }
        // vacc += vec(elem)
        if (insn == c.accNext)
            {
            XTIRValue* vnext = newVal(vecTy);
            XTIROperand* velem = vecOperand([XTIROperand useWithValueId:c.elemId]);
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVAdd
                                                         result:vnext
                                                       operands:@[ [XTIROperand useWithValueId:vacc.valueId], velem ]
                                                         dbgLoc:insn.dbgLoc]];
            vmap[@(insn.result.valueId)] = vnext; // accNext id → vector next
            continue;
            }
        switch (insn.opcode)
            {
        case XTIROpAddrOf:
        case XTIROpElementAddr:
        case XTIROpConst:
        case XTIROpZExt:
        case XTIROpSExt:
        case XTIROpTrunc:
            [newBody addObject:insn];
            break;
        case XTIROpLoad:
            {
            XTIRValue* vr = newVal(vecTy);
            XTIRInsn* vl = [[XTIRInsn alloc] initWithOpcode:XTIROpVLoad
                                                     result:vr
                                                   operands:insn.operands
                                                     dbgLoc:insn.dbgLoc];
            vl.memoryResult = insn.memoryResult;
            [newBody addObject:vl];
            vmap[@(insn.result.valueId)] = vr;
            break;
            }
        // elementwise arith
        default:
            {
            XTIROperand* va = vecOperand(insn.operands[0]);
            XTIROperand* vb = vecOperand(insn.operands[1]);
            XTIRValue* vr = newVal(vecTy);
            [newBody addObject:[[XTIRInsn alloc] initWithOpcode:vectorOpFor(insn.opcode)
                                                         result:vr
                                                       operands:@[ va, vb ]
                                                         dbgLoc:insn.dbgLoc]];
            vmap[@(insn.result.valueId)] = vr;
            break;
            }
            }
        }
    [B.instructions setArray:newBody];

    XTIRValue* vnext = vmap[@(c.accNext.result.valueId)]; // vector accNext id

    // Vector accumulator phi: [(preheader, vacc0), (B, vnext)]. The preheader
    // initialises the lanes to 0 (a VSplat of a scalar zero). vacc / vacc0 /
    // vnext are coalesced onto one v-register by the backend (associative
    // in-place accumulate), so the back-edge needs no copy.
    XTIRValue* vacc0 = newVal(vecTy);
    XTIRValue* zero = newVal(c.laneType);
    XTIRInsn* zc = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                             result:zero
                                           operands:@[ [XTIROperand immIWithType:c.laneType value:0] ]
                                             dbgLoc:nil];
    XTIRInsn* sp = [[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                             result:vacc0
                                           operands:@[ [XTIROperand useWithValueId:zero.valueId] ]
                                             dbgLoc:nil];
    // Insert init before the preheader's terminator.
    [PH.instructions addObject:zc];
    [PH.instructions addObject:sp];

    XTIRInsn* vphi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                               result:vacc
                                             operands:@[ [XTIROperand blockWithRef:PH], [XTIROperand useWithValueId:vacc0.valueId],
                                                         [XTIROperand blockWithRef:B], [XTIROperand useWithValueId:vnext.valueId] ]
                                               dbgLoc:nil];
    // Replace the scalar accumulator phi with the vector one; keep the iv phi.
    NSMutableArray<XTIRInsn*>* newPhis = [NSMutableArray array];
    for (XTIRInsn* phi in H.phiNodes)
        if (phi != c.accPhi)
            [newPhis addObject:phi];
    [newPhis addObject:vphi];
    [H.phiNodes setArray:newPhis];

    // Horizontal reduce at loop exit: scalar = addv(vacc); if the accumulator
    // started non-zero, add the initial scalar back. Rewire external uses of
    // the old scalar accumulator phi to the reduced result.
    XTIRValue* red = newVal(c.laneType);
    XTIRInsn* rd = [[XTIRInsn alloc] initWithOpcode:XTIROpVReduceAdd
                                             result:red
                                           operands:@[ [XTIROperand useWithValueId:vacc.valueId] ]
                                             dbgLoc:nil];
    NSMutableArray<XTIRInsn*>* head = [@[ rd ] mutableCopy];
    XTIRValueId outId = red.valueId;
    int64_t initK = 0;
    BOOL initIsZero = resolveConstInt(c.seedOp, ({
                                          NSMutableDictionary<NSNumber*, XTIRInsn*>* d = [NSMutableDictionary dictionary];
                                          for (XTIRBlock* bb in fn.blocks)
                                              for (XTIRInsn* i in bb.instructions)
                                                  if (i.result)
                                                      d[@(i.result.valueId)] = i;
                                          d;
                                      }),
                                      &initK) &&
                      initK == 0;
    if (!initIsZero)
        {
        XTIRValue* withInit = newVal(c.laneType);
        [head addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                  result:withInit
                                                operands:@[ [XTIROperand useWithValueId:red.valueId], c.seedOp ]
                                                  dbgLoc:nil]];
        outId = withInit.valueId;
        }
    // ── Epilogue, part 2: the reduction lands in a new block between the vector
    // loop and the remainder, because the remainder's accumulator STARTS from it.
    XTIRValueId finalId = outId;
    if (c.needsEpilogue)
        {
        XTIRBlock* VE = [[XTIRBlock alloc] init];
        VE.name = [NSString stringWithFormat:@"%@_vexit", H.name ?: @"hdr"];
        for (XTIRInsn* i in head)
            [VE appendInstruction:i];
        [VE setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                    result:nil
                                                  operands:@[ [XTIROperand blockWithRef:H2] ]
                                                    dbgLoc:nil]];

        // The vector loop exits to VE instead of E.
        NSMutableArray<XTIROperand*>* tops = [H.terminator.operands mutableCopy];
        for (NSUInteger k = 0; k < tops.count; k++)
            if (tops[k].kind == XTIROperandKindBlock && tops[k].blockRef == E)
                tops[k] = [XTIROperand blockWithRef:VE];
        [H.terminator replaceOperands:tops];

        // Seed the clone: its iv enters at M, its accumulator at the reduced
        // vector total. Both arrive on the edge from VE, which is where the
        // clone's phis still name the ORIGINAL preheader.
        XTIRValueId ivCloneId = (XTIRValueId)cmap[@(c.ivPhi.result.valueId)].unsignedLongLongValue;
        XTIRValueId accCloneId = (XTIRValueId)cmap[@(c.accPhi.result.valueId)].unsignedLongLongValue;
        for (XTIRInsn* phi in H2.phiNodes)
            {
            NSMutableArray<XTIROperand*>* pops = [phi.operands mutableCopy];
            for (NSUInteger k = 0; k + 1 < pops.count; k += 2)
                {
                if (!(pops[k].kind == XTIROperandKindBlock && pops[k].blockRef == PH))
                    continue;
                pops[k] = [XTIROperand blockWithRef:VE];
                if (phi.result.valueId == ivCloneId)
                    pops[k + 1] = c.runtimeTrip
                                      ? [XTIROperand useWithValueId:runtimeMId]
                                      : [XTIROperand immIWithType:c.ivPhi.result.type value:c.epiM];
                else if (phi.result.valueId == accCloneId)
                    pops[k + 1] = [XTIROperand useWithValueId:outId];
                }
            [phi replaceOperands:pops];
            }
        // Everything after the loop reads the REMAINDER's accumulator now.
        finalId = accCloneId;

        NSUInteger at = [fn.blocks indexOfObjectIdenticalTo:B];
        [fn.blocks insertObjects:@[ VE, H2, B2 ]
                       atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(at + 1, 3)]];
        }
    else
        {
        [E.instructions insertObjects:head
                            atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, head.count)]];
        }

    // Rewire uses of the old scalar accumulator (outside H/B) to the reduce.
    for (XTIRBlock* bb in fn.blocks)
        {
        // The clone is a copy of the ORIGINAL loop and legitimately reads the
        // original accumulator id through its own remapped values; rewriting
        // inside it would point the remainder at its own result.
        if (bb == H || bb == B || bb == H2 || bb == B2)
            continue;
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn == rd)
                continue;
            NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
            BOOL changed = NO;
            for (NSUInteger k = 0; k < ops.count; k++)
                {
                XTIROperand* o = ops[k];
                if (o.kind == XTIROperandKindUse && o.valueId == c.accId)
                    {
                    ops[k] = [XTIROperand useWithValueId:finalId];
                    changed = YES;
                    }
                }
            if (changed)
                [insn replaceOperands:ops];
            }
        }
    }

// ── Min/max reduction recognition ────────────────────────────────────────
//
// `for (i<N) if (a[i] <cmp> m) m = a[i]` lowers to a diamond the if-converter
// can't linearise (the then-arm reloads a[i], a Load it won't speculate). We
// recognise the diamond directly: header carries the iv + accumulator phis; the
// loop body is { head: load+compare+condbranch, then: [reload], join: phi }.
// Transformed to a vector umax/umin accumulate + a horizontal umaxv/uminv.
- (nullable XTVecCand*)recogniseMaxMin:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result)
                {
                defOf[@(p.result.valueId)] = p;
                defBlk[@(p.result.valueId)] = bb;
                }
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                {
                defOf[@(i.result.valueId)] = i;
                defBlk[@(i.result.valueId)] = bb;
                }
        }

    for (XTIRBlock* H in fn.blocks)
        {
        if (H.phiNodes.count != 2)
            continue;
        BOOL headerPure = YES;
        for (XTIRInsn* insn in H.instructions)
            if (insn.memoryResult)
                {
                headerPure = NO;
                break;
                }
        if (!headerPure)
            continue;

        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || defBlk[@(term.operands[0].valueId)] != H)
            continue;
        if (guard.operands.count < 2 || guard.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRValueId ivId = guard.operands[0].valueId;
        XTIRInsn *ivPhi = nil, *accPhi = nil;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.memoryResult || phi.operands.count != 4)
                {
                ivPhi = nil;
                break;
                }
            if (phi.result.valueId == ivId)
                ivPhi = phi;
            else
                accPhi = phi;
            }
        if (!ivPhi || !accPhi)
            continue;
        XTIRValueId accId = accPhi.result.valueId;
        int64_t N = 0;
        if (!resolveConstInt(guard.operands[1], defOf, &N) || N <= 0)
            continue;

        // Both the preheader (loop entry) and the latch (back-edge) branch to H,
        // so distinguish by block order: the latch follows H (back-edge), the
        // preheader precedes it. Both phis must agree on the same latch.
        NSUInteger idxH = [fn.blocks indexOfObjectIdenticalTo:H];
        XTIRBlock* (^incoming)(XTIRInsn*, BOOL) = ^XTIRBlock*(XTIRInsn* phi, BOOL wantLatch) {
          XTIRBlock *b0 = phi.operands[0].blockRef, *b1 = phi.operands[2].blockRef;
          NSUInteger i0 = [fn.blocks indexOfObjectIdenticalTo:b0];
          NSUInteger i1 = [fn.blocks indexOfObjectIdenticalTo:b1];
          if (i0 == NSNotFound || i1 == NSNotFound)
              return nil;
          BOOL b0latch = i0 > idxH; // back-edge source follows H
          if (wantLatch)
              return b0latch ? b0 : b1;
          return b0latch ? b1 : b0;
        };
        XTIRBlock* L = incoming(accPhi, YES);
        XTIRBlock* PH = incoming(accPhi, NO);
        if (!L || !PH || L == H || L == PH)
            continue;
        if (incoming(ivPhi, YES) != L)
            continue; // both phis latch via L
        if (!L.terminator || L.terminator.opcode != XTIROpBranch ||
            L.terminator.operands.count < 1 || L.terminator.operands[0].blockRef != H)
            continue;

        // L (join): preds {body, then}; holds accNext phi + ivNext add + Branch H.
        if (L.phiNodes.count != 1 || L.terminator.opcode != XTIROpBranch)
            continue;
        XTIRInsn* accNextPhi = L.phiNodes[0];
        if (!accNextPhi.result || accNextPhi.operands.count != 4)
            continue;
        // accPhi's back-edge value must be this join phi.
        XTIROperand* accBack = (accPhi.operands[0].blockRef == L) ? accPhi.operands[1] : accPhi.operands[3];
        if (accBack.kind != XTIROperandKindUse || accBack.valueId != accNextPhi.result.valueId)
            continue;

        // Body = guard target that is a pred of L (the diamond head); exit = other.
        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        XTIRBlock *jb0 = accNextPhi.operands[0].blockRef, *jb1 = accNextPhi.operands[2].blockRef;
        XTIRBlock *B = nil, *E = nil;
        if (t0 == jb0 || t0 == jb1)
            {
            B = t0;
            E = t1;
            }
        else if (t1 == jb0 || t1 == jb1)
            {
            B = t1;
            E = t0;
            }
        else
            continue;
        XTIRBlock* TH = (jb0 == B) ? jb1 : jb0; // the then arm
        if (!B || !E || !TH || B == TH)
            continue;
        if (B.phiNodes.count != 0 || E.phiNodes.count != 0)
            continue;

        // Body: ElementAddr(base,iv) + Load(elem) + ICmp(elem,acc), ends in
        // CondBranch(cmp, {TH or L}, {L or TH}). No other memory/side effects.
        XTIRInsn* bterm = B.terminator;
        if (!bterm || bterm.opcode != XTIROpCondBranch || bterm.operands.count < 3)
            continue;
        if (bterm.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* cmp = defOf[@(bterm.operands[0].valueId)];
        if (!cmp || cmp.opcode != XTIROpICmp || defBlk[@(bterm.operands[0].valueId)] != B)
            continue;
        XTIRValueId elemId = 0;
        XTIRType* laneType = nil;
        BOOL ok = YES;
        for (XTIRInsn* insn in B.instructions)
            {
            XTIROpcode op = insn.opcode;
            if (op == XTIROpAddrOf)
                continue;
            if (op == XTIROpElementAddr)
                {
                if (insn.operands.count < 2 || insn.operands[1].kind != XTIROperandKindUse ||
                    insn.operands[1].valueId != ivId)
                    {
                    ok = NO;
                    break;
                    }
                continue;
                }
            if (op == XTIROpLoad)
                {
                if (insn.operands.count < 1 || insn.operands[0].kind != XTIROperandKindUse || !insn.result)
                    {
                    ok = NO;
                    break;
                    }
                XTIRInsn* ea = defOf[@(insn.operands[0].valueId)];
                if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count < 2 ||
                    ea.operands[1].kind != XTIROperandKindUse || ea.operands[1].valueId != ivId)
                    {
                    ok = NO;
                    break;
                    }
                XTIRType* lt = insn.result.type;
                if (!lt || !(lt.kind == XTIRTypeKindI32 || lt.kind == XTIRTypeKindU32))
                    {
                    ok = NO;
                    break;
                    }
                elemId = insn.result.valueId;
                laneType = lt;
                continue;
                }
            if (op == XTIROpICmp || op == XTIROpConst || op == XTIROpZExt ||
                op == XTIROpSExt || op == XTIROpTrunc)
                continue;
            ok = NO;
            break;
            }
        if (!ok || !laneType || elemId == 0)
            continue;

        // then arm: pred = B only, no phis, pure-ish (only a reload of elem), Branch L.
        if (TH.phiNodes.count != 0 || !TH.terminator || TH.terminator.opcode != XTIROpBranch ||
            TH.terminator.operands.count < 1 || TH.terminator.operands[0].blockRef != L)
            continue;
        for (XTIRInsn* insn in TH.instructions)
            {
            XTIROpcode op = insn.opcode;
            if (op == XTIROpAddrOf || op == XTIROpElementAddr || op == XTIROpLoad)
                continue;
            ok = NO;
            break;
            }
        if (!ok)
            continue;

        // join phi arms: one arm == acc (kept when not selected), the other ==
        // elem (the reload, or elemId directly). The acc-arm comes from B, the
        // elem-arm from TH (matching the `if (cmp) m = a[i]` shape).
        XTIROperand* armFromB = (accNextPhi.operands[0].blockRef == B) ? accNextPhi.operands[1] : accNextPhi.operands[3];
        XTIROperand* armFromTH = (accNextPhi.operands[0].blockRef == TH) ? accNextPhi.operands[1] : accNextPhi.operands[3];
        if (armFromB.kind != XTIROperandKindUse || armFromB.valueId != accId)
            continue;
        if (armFromTH.kind != XTIROperandKindUse)
            continue;
        BOOL armIsElem = (armFromTH.valueId == elemId);
        // a reload of the same element
        if (!armIsElem)
            {
            XTIRInsn* rl = defOf[@(armFromTH.valueId)];
            if (!rl || rl.opcode != XTIROpLoad || defBlk[@(armFromTH.valueId)] != TH ||
                rl.operands.count < 1 || rl.operands[0].kind != XTIROperandKindUse)
                continue;
            XTIRInsn* ea = defOf[@(rl.operands[0].valueId)];
            if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count < 2 ||
                ea.operands[1].kind != XTIROperandKindUse || ea.operands[1].valueId != ivId)
                continue;
            }

        // ivNext = Add(iv,1) in L, used once (the iv phi back-edge).
        XTIRInsn* ivNext = nil;
        for (XTIRInsn* insn in L.instructions)
            if (insn.opcode == XTIROpAdd && insn.result)
                {
                int64_t one = 0;
                XTIROperand* so = nil;
                if (insn.operands[0].kind == XTIROperandKindUse && insn.operands[0].valueId == ivId)
                    so = insn.operands[1];
                else if (insn.operands[1].kind == XTIROperandKindUse && insn.operands[1].valueId == ivId)
                    so = insn.operands[0];
                if (so && resolveConstInt(so, defOf, &one) && one == 1)
                    {
                    ivNext = insn;
                    break;
                    }
                }
        if (!ivNext)
            continue;
        XTIROperand* ivBack = (ivPhi.operands[0].blockRef == L) ? ivPhi.operands[1] : ivPhi.operands[3];
        if (ivBack.kind != XTIROperandKindUse || ivBack.valueId != ivNext.result.valueId)
            continue;

        // Classify max vs min + signedness from the compare (operands are elem
        // and acc; the elem arm of the select is chosen when cmp is true).
        XTIROperand *ca = cmp.operands[0], *cb = cmp.operands[1];
        BOOL cmpElemLeft;
        if (ca.kind == XTIROperandKindUse && ca.valueId == elemId &&
            cb.kind == XTIROperandKindUse && cb.valueId == accId)
            cmpElemLeft = YES;
        else if (ca.kind == XTIROperandKindUse && ca.valueId == accId &&
                 cb.kind == XTIROperandKindUse && cb.valueId == elemId)
            cmpElemLeft = NO;
        else
            continue;
        uint8_t pred = cmp.predicate;
        BOOL gtFam = (pred == XTIRICmpUGT || pred == XTIRICmpSGT || pred == XTIRICmpUGE || pred == XTIRICmpSGE);
        BOOL ltFam = (pred == XTIRICmpULT || pred == XTIRICmpSLT || pred == XTIRICmpULE || pred == XTIRICmpSLE);
        if (!gtFam && !ltFam)
            continue;
        BOOL signedCmp = (pred == XTIRICmpSGT || pred == XTIRICmpSLT || pred == XTIRICmpSGE || pred == XTIRICmpSLE);
        if (signedCmp != (laneType.kind == XTIRTypeKindI32))
            continue;
        // cmp true selects elem. elem-is-larger ⟺ max.
        //  elem-left  GT  → elem>acc → true keeps elem(larger) → MAX
        //  elem-left  LT  → MIN ;  acc-left GT → acc>elem → keep elem(smaller) → MIN ; acc-left LT → MAX
        BOOL isMax = cmpElemLeft ? gtFam : ltFam;

        XTIROperand* seedOp = (accPhi.operands[0].blockRef == L) ? accPhi.operands[3] : accPhi.operands[1];

        NSUInteger vw = 16 / laneType.byteWidth;
        // The iteration space is [ivStart, N), so it is the trip LENGTH that must
        // be a whole number of vectors — not the bound. Gating on `N % vw` was
        // right only for a zero start, and silently wrong for any other: with
        // `for (i = 2; i < 16; i++)` and vw=4 it accepted 16%4==0 while the real
        // length is 14, which is how the vector store ran past the range.
        // These two recognisers have no epilogue, so an uneven length stays
        // scalar; the three that do take the tail instead.
        int64_t ivStart = 0;
        if (!xtvIvStartConst(ivPhi, L, defOf, &ivStart))
            continue;
        if (ivStart >= N)
            continue;
        if (vw < 2 || (((N - ivStart) % (int64_t)vw) != 0))
            continue;

        XTVecCand* c = [XTVecCand new];
        c.H = H;
        c.B = B;
        c.E = E;
        c.ivPhi = ivPhi;
        c.ivNext = ivNext;
        c.guard = guard;
        c.ivId = ivId;
        c.laneType = laneType;
        c.vw = vw;
        c.accPhi = accPhi;
        c.accId = accId;
        c.elemId = elemId;
        c.seedOp = seedOp;
        c.preheader = PH;
        c.isMaxMin = YES;
        c.isMax = isMax;
        c.mmThen = TH;
        c.mmLatch = L;
        return c;
        }
    return nil;
    }

- (void)applyMaxMin:(XTVecCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock *B = c.B, *H = c.H, *E = c.E, *PH = c.preheader, *L = c.mmLatch;
    XTIRType* vecTy = [XTIRType vecWithLane:c.laneType];
    XTIRValue* (^newVal)(XTIRType*) = ^XTIRValue*(XTIRType* ty) {
      XTIRValueId rid = [fn allocateValueId];
      XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                   type:ty
                                                defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:0]];
      [fn registerValue:v];
      return v;
    };

    XTIRValue* vacc = newVal(vecTy);

    // Rebuild B as the single straight-line vector latch: keep the address
    // computation, vector-load the element, fold it into the accumulator with
    // VMax/VMin, step the iv by the vector width, then branch to H.
    NSMutableArray<XTIRInsn*>* nb = [NSMutableArray array];
    XTIRValue* vload = nil;
    for (XTIRInsn* insn in B.instructions)
        {
        if (insn.opcode == XTIROpLoad && insn.result && insn.result.valueId == c.elemId)
            {
            vload = newVal(vecTy);
            XTIRInsn* vl = [[XTIRInsn alloc] initWithOpcode:XTIROpVLoad
                                                     result:vload
                                                   operands:insn.operands
                                                     dbgLoc:insn.dbgLoc];
            vl.memoryResult = insn.memoryResult;
            [nb addObject:vl];
            }
        else if (insn.opcode == XTIROpAddrOf || insn.opcode == XTIROpElementAddr ||
                 insn.opcode == XTIROpConst)
            {
            [nb addObject:insn]; // keep address plumbing
            }
        // ICmp / casts are dropped (folded into the vector min/max).
        }
    XTIRValue* vnext = newVal(vecTy);
    [nb addObject:[[XTIRInsn alloc] initWithOpcode:(c.isMax ? XTIROpVMax : XTIROpVMin)
                                            result:vnext
                                          operands:@[ [XTIROperand useWithValueId:vacc.valueId], [XTIROperand useWithValueId:vload.valueId] ]
                                            dbgLoc:nil]];
    XTIRValue* ivNext = newVal(c.ivNext.result.type);
    [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                            result:ivNext
                                          operands:@[ [XTIROperand useWithValueId:c.ivId],
                                                      [XTIROperand immIWithType:c.ivNext.result.type
                                                                          value:(int64_t)c.vw] ]
                                            dbgLoc:nil]];
    [B.instructions setArray:nb];
    [B resetTerminator];
    [B setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                               result:nil
                                             operands:@[ [XTIROperand blockWithRef:H] ]
                                               dbgLoc:nil]];

    // Vector accumulator phi in H: init = splat(seed) (min/max are idempotent,
    // so seeding all lanes is correct without an end-combine); back-edge = vnext
    // from B (the new latch). Replace the scalar accumulator phi.
    XTIRValue* vacc0 = newVal(vecTy);
    XTIRInsn* sp = [[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                             result:vacc0
                                           operands:@[ c.seedOp ]
                                             dbgLoc:nil];
    [PH.instructions addObject:sp];
    XTIRInsn* vphi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                               result:vacc
                                             operands:@[ [XTIROperand blockWithRef:PH], [XTIROperand useWithValueId:vacc0.valueId],
                                                         [XTIROperand blockWithRef:B], [XTIROperand useWithValueId:vnext.valueId] ]
                                               dbgLoc:nil];
    NSMutableArray<XTIRInsn*>* newPhis = [NSMutableArray array];
    for (XTIRInsn* phi in H.phiNodes)
        {
        if (phi == c.accPhi)
            {
            [newPhis addObject:vphi];
            continue;
            }
        // iv phi: retarget its back-edge from the old latch L to the new latch B.
        NSMutableArray<XTIROperand*>* ops = [phi.operands mutableCopy];
        for (NSUInteger k = 0; k + 1 < ops.count; k += 2)
            {
            if (ops[k].kind == XTIROperandKindBlock && ops[k].blockRef == L)
                {
                ops[k] = [XTIROperand blockWithRef:B];
                ops[k + 1] = [XTIROperand useWithValueId:ivNext.valueId];
                }
            }
        [phi replaceOperands:ops];
        [newPhis addObject:phi];
        }
    [H.phiNodes setArray:newPhis];

    // The memory chain has to be repaired BEFORE the diamond goes: the scalar
    // loop threaded its token through the then-arm's reload, so post-loop code
    // reads a token defined in a block that is about to disappear. Every memory
    // result defined in the arm or the join becomes the surviving VLoad's token
    // (the loop's last memory op). Without this the exit block references a
    // value with no definition — the printer spells it `%?36`, and a backend
    // that resolves tokens by id would read a dead slot.
    NSMutableSet<NSNumber*>* goneMem = [NSMutableSet set];
    for (XTIRBlock* bb in @[ c.mmThen, L ])
        for (XTIRInsn* insn in bb.instructions)
            {
            if (insn.memoryResult)
                [goneMem addObject:@(insn.memoryResult.valueId)];
            if (insn.result)
                [goneMem addObject:@(insn.result.valueId)];
            }
    XTIRValueId liveMem = vload.valueId; // placeholder; replaced below
    for (XTIRInsn* insn in B.instructions)
        if (insn.memoryResult)
            liveMem = insn.memoryResult.valueId;
    if (goneMem.count)
        {
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == L || bb == c.mmThen)
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
                    if (ops[k].kind == XTIROperandKindUse &&
                        [goneMem containsObject:@(ops[k].valueId)])
                        {
                        ops[k] = [XTIROperand useWithValueId:liveMem];
                        changed = YES;
                        }
                if (changed)
                    [insn replaceOperands:ops];
                }
            }
        }

    // Drop the now-dead diamond arm + join.
    NSMutableArray<XTIRBlock*>* keep = [NSMutableArray array];
    for (XTIRBlock* bb in fn.blocks)
        if (bb != L && bb != c.mmThen)
            [keep addObject:bb];
    [fn.blocks setArray:keep];

    // Horizontal reduce at the exit; rewire live-out uses of the old accumulator.
    XTIRValue* red = newVal(c.laneType);
    XTIRInsn* rd = [[XTIRInsn alloc] initWithOpcode:(c.isMax ? XTIROpVReduceMax : XTIROpVReduceMin)
                                             result:red
                                           operands:@[ [XTIROperand useWithValueId:vacc.valueId] ]
                                             dbgLoc:nil];
    [E.instructions insertObject:rd atIndex:0];
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
            {
            if (insn == rd)
                continue;
            NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
            BOOL changed = NO;
            for (NSUInteger k = 0; k < ops.count; k++)
                if (ops[k].kind == XTIROperandKindUse && ops[k].valueId == c.accId)
                    {
                    ops[k] = [XTIROperand useWithValueId:red.valueId];
                    changed = YES;
                    }
            if (changed)
                [insn replaceOperands:ops];
            }
        }
    }

// ── Conditional-count reduction recognition ──────────────────────────────
//
// `for (i<N) if (a[i] <cmp> k) c += d` — if-converts to a straight-line body
// whose accumulator back-edge is `accNext = Select(ICmp(elem,k), Add(acc,d), acc)`.
// It is an additive reduction with a masked increment, so vectorise it as
// `vacc += (VICmp(vload, splat k) & splat d)` + a horizontal add at exit. The
// body (Select) and the iv-step often sit in separate blocks (body → join →
// header); we vectorise the body block in place and only re-step the iv.
- (nullable XTVecCand*)recogniseCountReduction:(XTIRFunction*)fn
    {
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

    for (XTIRBlock* H in fn.blocks)
        {
        if (H.phiNodes.count != 2)
            continue;
        BOOL headerPure = YES;
        for (XTIRInsn* insn in H.instructions)
            if (insn.memoryResult)
                {
                headerPure = NO;
                break;
                }
        if (!headerPure)
            continue;

        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || defBlk[@(term.operands[0].valueId)] != H)
            continue;
        if (guard.operands.count < 2 || guard.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRValueId ivId = guard.operands[0].valueId;
        XTIRInsn *ivPhi = nil, *accPhi = nil;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.memoryResult || phi.operands.count != 4)
                {
                ivPhi = nil;
                break;
                }
            if (phi.result.valueId == ivId)
                ivPhi = phi;
            else
                accPhi = phi;
            }
        if (!ivPhi || !accPhi)
            continue;
        XTIRValueId accId = accPhi.result.valueId;
        int64_t N = 0;
        if (!resolveConstInt(guard.operands[1], defOf, &N) || N <= 0)
            continue;

        // Latch L (back-edge block, follows H); preheader precedes H. Both phis agree.
        NSUInteger idxH = [fn.blocks indexOfObjectIdenticalTo:H];
        XTIRBlock* (^incoming)(XTIRInsn*, BOOL) = ^XTIRBlock*(XTIRInsn* phi, BOOL wantLatch) {
          XTIRBlock *b0 = phi.operands[0].blockRef, *b1 = phi.operands[2].blockRef;
          NSUInteger i0 = [fn.blocks indexOfObjectIdenticalTo:b0];
          NSUInteger i1 = [fn.blocks indexOfObjectIdenticalTo:b1];
          if (i0 == NSNotFound || i1 == NSNotFound)
              return nil;
          BOOL b0latch = i0 > idxH;
          if (wantLatch)
              return b0latch ? b0 : b1;
          return b0latch ? b1 : b0;
        };
        XTIRBlock* L = incoming(accPhi, YES);
        XTIRBlock* PH = incoming(accPhi, NO);
        if (!L || !PH || L == H || L == PH || incoming(ivPhi, YES) != L)
            continue;
        if (!L.terminator || L.terminator.opcode != XTIROpBranch ||
            L.terminator.operands.count < 1 || L.terminator.operands[0].blockRef != H ||
            L.phiNodes.count != 0)
            continue;

        // B = guard target that leads into the loop (== L when merged, else a
        // single-successor block that branches to L). E = the other guard target.
        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        BOOL (^leadsToL)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b == L || (b && b != H && b.phiNodes.count == 0 && b.terminator &&
                            b.terminator.opcode == XTIROpBranch && b.terminator.operands.count >= 1 &&
                            b.terminator.operands[0].blockRef == L);
        };
        XTIRBlock *B = nil, *E = nil;
        if (leadsToL(t0))
            {
            B = t0;
            E = t1;
            }
        else if (leadsToL(t1))
            {
            B = t1;
            E = t0;
            }
        else
            continue;
        if (!E || E.phiNodes.count != 0)
            continue;

        // accNext = acc phi back-edge value: a Select defined in B.
        XTIROperand* accBack = (accPhi.operands[0].blockRef == L) ? accPhi.operands[1] : accPhi.operands[3];
        if (accBack.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* accNext = defOf[@(accBack.valueId)];
        if (!accNext || accNext.opcode != XTIROpSelect || accNext.operands.count < 3 ||
            defBlk[@(accBack.valueId)] != B)
            continue;
        if ([uses countForObject:@(accBack.valueId)] != 1)
            continue;
        // Select(cmp, Add(acc, delta), acc): cond true → increment (canonical).
        XTIROperand *condOp = accNext.operands[0], *tOp = accNext.operands[1], *fOp = accNext.operands[2];
        if (condOp.kind != XTIROperandKindUse || tOp.kind != XTIROperandKindUse ||
            fOp.kind != XTIROperandKindUse)
            continue;
        if (fOp.valueId != accId)
            continue; // unselected arm keeps acc
        XTIRInsn* incr = defOf[@(tOp.valueId)];
        if (!incr || incr.opcode != XTIROpAdd || defBlk[@(tOp.valueId)] != B)
            continue;
        XTIROperand* deltaOp = nil;
        if (incr.operands[0].kind == XTIROperandKindUse && incr.operands[0].valueId == accId)
            deltaOp = incr.operands[1];
        else if (incr.operands[1].kind == XTIROperandKindUse && incr.operands[1].valueId == accId)
            deltaOp = incr.operands[0];
        if (!deltaOp)
            continue;
        int64_t deltaK;
        if (!resolveConstInt(deltaOp, defOf, &deltaK))
            continue; // invariant increment
        XTIRInsn* cmp = defOf[@(condOp.valueId)];
        if (!cmp || cmp.opcode != XTIROpICmp || cmp.operands.count < 2 || defBlk[@(condOp.valueId)] != B)
            continue;

        // ivNext = Add(iv,1) in the latch L (== B when the body is merged), the
        // iv phi's back-edge. Found before classification so the body classifier
        // can skip it (when merged it shares the block with the count plumbing).
        XTIRInsn* ivNext = nil;
        for (XTIRInsn* insn in L.instructions)
            if (insn.opcode == XTIROpAdd && insn.result)
                {
                int64_t one = 0;
                XTIROperand* so = nil;
                if (insn.operands[0].kind == XTIROperandKindUse && insn.operands[0].valueId == ivId)
                    so = insn.operands[1];
                else if (insn.operands[1].kind == XTIROperandKindUse && insn.operands[1].valueId == ivId)
                    so = insn.operands[0];
                if (so && resolveConstInt(so, defOf, &one) && one == 1)
                    {
                    ivNext = insn;
                    break;
                    }
                }
        if (!ivNext)
            continue;
        XTIROperand* ivBack = (ivPhi.operands[0].blockRef == L) ? ivPhi.operands[1] : ivPhi.operands[3];
        if (ivBack.kind != XTIROperandKindUse || ivBack.valueId != ivNext.result.valueId)
            continue;

        // Classify B: the elementwise computation feeding the compare. Skip the
        // count plumbing (the compare, the increment Add, the Select, the iv step).
        XTIRType* laneType = nil;
        BOOL ok = YES;
        XTIRValueId elemId = 0;
        NSMutableSet<NSNumber*>* elemIds = [NSMutableSet set];
        BOOL (^isElemAddrAtIv)(XTIROperand*) = ^BOOL(XTIROperand* p) {
          if (p.kind != XTIROperandKindUse)
              return NO;
          XTIRInsn* ea = defOf[@(p.valueId)];
          return ea && ea.opcode == XTIROpElementAddr && ea.operands.count >= 2 &&
                 ea.operands[1].kind == XTIROperandKindUse && ea.operands[1].valueId == ivId;
        };
        BOOL (^elemOperandOK)(XTIROperand*) = ^BOOL(XTIROperand* o) {
          if (o.kind == XTIROperandKindImmI)
              return YES;
          if (o.kind != XTIROperandKindUse)
              return NO;
          if ([elemIds containsObject:@(o.valueId)])
              return YES;
          int64_t kk;
          if (resolveConstInt(o, defOf, &kk))
              return YES;
          XTIRBlock* db = defBlk[@(o.valueId)];
          return db != nil && db != B && db != L && db != H;
        };
        for (XTIRInsn* insn in B.instructions)
            {
            if (insn == cmp || insn == incr || insn == accNext || insn == ivNext)
                continue;
            XTIROpcode op = insn.opcode;
            if (op == XTIROpAddrOf || op == XTIROpConst || op == XTIROpZExt ||
                op == XTIROpSExt || op == XTIROpTrunc)
                continue;
            if (op == XTIROpElementAddr)
                {
                if (insn.operands.count < 2 || insn.operands[1].kind != XTIROperandKindUse ||
                    insn.operands[1].valueId != ivId)
                    {
                    ok = NO;
                    break;
                    }
                continue;
                }
            if (op == XTIROpLoad)
                {
                if (insn.operands.count < 1 || !isElemAddrAtIv(insn.operands[0]) || !insn.result)
                    {
                    ok = NO;
                    break;
                    }
                XTIRType* lt = insn.result.type;
                // A NARROW element counts too: the compare and mask run at the
                // load's width and climb to the accumulator's with VAddLP. A
                // narrow lane only ever holds ONE iteration's mask before being
                // widened — the accumulation happens at 32 bits — so there is no
                // overflow to reason about beyond the delta fitting the lane.
                if (!lt || !(lt.kind == XTIRTypeKindI32 || lt.kind == XTIRTypeKindU32 ||
                             lt.kind == XTIRTypeKindI8  || lt.kind == XTIRTypeKindU8 ||
                             lt.kind == XTIRTypeKindI16 || lt.kind == XTIRTypeKindU16))
                    {
                    ok = NO;
                    break;
                    }
                if (laneType && laneType.kind != lt.kind)
                    {
                    ok = NO;
                    break;
                    }
                laneType = lt;
                elemId = insn.result.valueId;
                [elemIds addObject:@(insn.result.valueId)];
                continue;
                }
            if (elementwiseArith(op))
                {
                if (!insn.result || insn.operands.count < 2 ||
                    !elemOperandOK(insn.operands[0]) || !elemOperandOK(insn.operands[1]))
                    {
                    ok = NO;
                    break;
                    }
                [elemIds addObject:@(insn.result.valueId)];
                continue;
                }
            ok = NO;
            break;
            }
        if (!ok || !laneType || elemId == 0)
            continue;
        // The compare must be elem-vs-invariant: one operand elementwise, the
        // other loop-invariant (constant or defined outside the loop).
        BOOL c0elem = cmp.operands[0].kind == XTIROperandKindUse && [elemIds containsObject:@(cmp.operands[0].valueId)];
        BOOL c1elem = cmp.operands[1].kind == XTIROperandKindUse && [elemIds containsObject:@(cmp.operands[1].valueId)];
        if (c0elem == c1elem)
            continue; // exactly one side elementwise
        XTIROperand* kSide = c0elem ? cmp.operands[1] : cmp.operands[0];
        if (!elemOperandOK(kSide) || [elemIds containsObject:@(kSide.valueId)])
            continue;
        if (cmp.predicate == XTIRICmpEQ || cmp.predicate == XTIRICmpNE ||
            cmp.predicate == XTIRICmpULT || cmp.predicate == XTIRICmpUGT ||
            cmp.predicate == XTIRICmpULE || cmp.predicate == XTIRICmpUGE ||
            cmp.predicate == XTIRICmpSLT || cmp.predicate == XTIRICmpSGT ||
            /* supported */
            cmp.predicate == XTIRICmpSLE || cmp.predicate == XTIRICmpSGE)
            {
            }
        else
            continue;

        // acc used in the loop only by the Select; iv must not escape.
        BOOL clean = YES;
        for (XTIRBlock* bb in @[ H, B, L ])
            {
            for (XTIRInsn* u in bb.instructions)
                {
                if (u == accNext || u == incr)
                    continue;
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == accId)
                        {
                        clean = NO;
                        break;
                        }
                if (!clean)
                    break;
                }
            if (!clean)
                break;
            }
        if (!clean)
            continue;
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B || bb == L)
                continue;
            for (XTIRInsn* u in bb.instructions)
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == ivId)
                        {
                        clean = NO;
                        break;
                        }
            }
        if (!clean)
            continue;

        XTIROperand* seedOp = (accPhi.operands[0].blockRef == L) ? accPhi.operands[3] : accPhi.operands[1];
        NSUInteger vw = 16 / laneType.byteWidth;
        // The iteration space is [ivStart, N), so it is the trip LENGTH that must
        // be a whole number of vectors — not the bound. Gating on `N % vw` was
        // right only for a zero start, and silently wrong for any other: with
        // `for (i = 2; i < 16; i++)` and vw=4 it accepted 16%4==0 while the real
        // length is 14, which is how the vector store ran past the range.
        // These two recognisers have no epilogue, so an uneven length stays
        // scalar; the three that do take the tail instead.
        int64_t ivStart = 0;
        if (!xtvIvStartConst(ivPhi, L, defOf, &ivStart))
            continue;
        if (ivStart >= N)
            continue;
        if (vw < 2 || (((N - ivStart) % (int64_t)vw) != 0))
            continue;

        XTVecCand* c = [XTVecCand new];
        c.H = H;
        c.B = B;
        c.E = E;
        c.ivPhi = ivPhi;
        c.ivNext = ivNext;
        c.guard = guard;
        c.ivId = ivId;
        // vw came from the LOAD's width above (16 lanes for a byte). When the
        // element is narrower than the count, the accumulator keeps its own
        // width and loadLaneType records the element's — exactly as the
        // widening sum does — and the apply climbs between them.
        XTIRType* accTy = accPhi.result.type;
        if (laneType.byteWidth < 4)
            {
            if (!accTy || accTy.byteWidth != 4)
                continue;                        // only a 32-bit count
            uint64_t laneMax = (laneType.byteWidth == 1) ? 0xFFULL : 0xFFFFULL;
            if (deltaK < 0 || (uint64_t)deltaK > laneMax)
                continue;                        // the delta must fit the lane
            c.loadLaneType = laneType;
            c.laneType = accTy;
            }
        else
            c.laneType = laneType;
        c.vw = vw;
        c.accPhi = accPhi;
        c.accId = accId;
        c.elemId = elemId;
        c.seedOp = seedOp;
        c.preheader = PH;
        c.mmLatch = L;
        c.isCount = YES;
        c.cmpInsn = cmp;
        c.countDeltaOp = deltaOp;
        return c;
        }
    return nil;
    }

- (void)applyCountReduction:(XTVecCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock *B = c.B, *H = c.H, *E = c.E, *PH = c.preheader, *L = c.mmLatch;
    // The load, compare and mask run at the ELEMENT's width; the accumulator
    // keeps its own. They are the same type unless the element is narrower,
    // which is what loadLaneType records — so the 32-bit path is unchanged.
    XTIRType* elemLane = c.loadLaneType ?: c.laneType;
    XTIRType* vecTy = [XTIRType vecWithLane:elemLane];
    XTIRType* accVecTy = [XTIRType vecWithLane:c.laneType];
    XTIRValue* (^newVal)(XTIRType*) = ^XTIRValue*(XTIRType* ty) {
      XTIRValueId rid = [fn allocateValueId];
      XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                   type:ty
                                                defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:0]];
      [fn registerValue:v];
      return v;
    };

    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                defOf[@(i.result.valueId)] = i;

    XTIRValue* vacc = newVal(accVecTy);
    NSMutableArray<XTIRInsn*>* nb = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, XTIRValue*>* vmap = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRValue*>* splat = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRValue*>* phSplatCache = [NSMutableDictionary dictionary];
    // Splat a LOOP-INVARIANT operand (the compare bound k, the increment delta)
    // into the preheader, so it is computed once on loop entry rather than every
    // iteration. A compile-time constant is rematerialised fresh in the
    // preheader; a value defined before the loop is splatted directly (it
    // dominates the preheader).
    XTIROperand* (^phSplat)(XTIROperand*) = ^XTIROperand*(XTIROperand* op) {
      NSNumber* cacheKey = (op.kind == XTIROperandKindUse) ? @(op.valueId) : nil;
      if (cacheKey && phSplatCache[cacheKey])
          return [XTIROperand useWithValueId:phSplatCache[cacheKey].valueId];
      XTIROperand* scalar = op;
      int64_t kv;
      if (resolveConstInt(op, defOf, &kv))
          {
          XTIRValue* cst = newVal(c.laneType);
          [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                               result:cst
                                                             operands:@[ [XTIROperand immIWithType:c.laneType value:kv] ]
                                                               dbgLoc:nil]];
          scalar = [XTIROperand useWithValueId:cst.valueId];
          }
      XTIRValue* sp = newVal(vecTy);
      [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                           result:sp
                                                         operands:@[ scalar ]
                                                           dbgLoc:nil]];
      if (cacheKey)
          phSplatCache[cacheKey] = sp;
      return [XTIROperand useWithValueId:sp.valueId];
    };
    XTIROperand* (^vecOperand)(XTIROperand*) = ^XTIROperand*(XTIROperand* op) {
      if (op.kind == XTIROperandKindUse)
          {
          XTIRValue* vv = vmap[@(op.valueId)];
          if (vv)
              return [XTIROperand useWithValueId:vv.valueId];
          XTIRValue* sp = splat[@(op.valueId)];
          if (!sp)
              {
              sp = newVal(vecTy);
              [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat result:sp operands:@[ op ] dbgLoc:nil]];
              splat[@(op.valueId)] = sp;
              }
          return [XTIROperand useWithValueId:sp.valueId];
          }
      XTIRValue* sp = newVal(vecTy);
      [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat result:sp operands:@[ op ] dbgLoc:nil]];
      return [XTIROperand useWithValueId:sp.valueId];
    };

    // Rebuild B: keep address/const plumbing, vector-load the element and any
    // elementwise arith; drop the scalar compare / increment / select.
    for (XTIRInsn* insn in B.instructions)
        {
        if (insn == c.cmpInsn || insn.opcode == XTIROpSelect)
            continue; // count plumbing
        // keep iv step scalar (merged body)
        if (insn == c.ivNext)
            {
            [nb addObject:insn];
            continue;
            }
        // the scalar c+delta
        if (insn.result && insn.opcode == XTIROpAdd)
            {
            // skip the increment Add (its result feeds only the Select)
            if (insn.operands[0].kind == XTIROperandKindUse && insn.operands[0].valueId == c.accId)
                continue;
            if (insn.operands[1].kind == XTIROperandKindUse && insn.operands[1].valueId == c.accId)
                continue;
            }
        if (insn.opcode == XTIROpLoad && insn.result)
            {
            XTIRValue* vr = newVal(vecTy);
            XTIRInsn* vl = [[XTIRInsn alloc] initWithOpcode:XTIROpVLoad
                                                     result:vr
                                                   operands:insn.operands
                                                     dbgLoc:insn.dbgLoc];
            vl.memoryResult = insn.memoryResult;
            [nb addObject:vl];
            vmap[@(insn.result.valueId)] = vr;
            }
        else if (insn.opcode == XTIROpAddrOf || insn.opcode == XTIROpElementAddr ||
                 insn.opcode == XTIROpConst || insn.opcode == XTIROpZExt ||
                 insn.opcode == XTIROpSExt || insn.opcode == XTIROpTrunc)
            {
            [nb addObject:insn];
            }
        else if (elementwiseArith(insn.opcode) && insn.result)
            {
            XTIROperand* va = vecOperand(insn.operands[0]);
            XTIROperand* vb = vecOperand(insn.operands[1]);
            XTIRValue* vr = newVal(vecTy);
            [nb addObject:[[XTIRInsn alloc] initWithOpcode:vectorOpFor(insn.opcode)
                                                    result:vr
                                                  operands:@[ va, vb ]
                                                    dbgLoc:insn.dbgLoc]];
            vmap[@(insn.result.valueId)] = vr;
            }
        }
    // vmask = VICmp(elem, k); vinc = vmask & splat(delta); vacc += vinc.
    // The elementwise side comes from the body (vmap); the loop-invariant bound
    // k and the increment delta are splatted once in the preheader.
    XTIROperand* (^cmpOperand)(XTIROperand*) = ^XTIROperand*(XTIROperand* op) {
      if (op.kind == XTIROperandKindUse && vmap[@(op.valueId)])
          return vecOperand(op); // elementwise
      int64_t kv;
      if (resolveConstInt(op, defOf, &kv))
          return phSplat(op); // constant → preheader
      return vecOperand(op);  // non-const invariant: body splat (always dominates)
    };
    XTIRValue* vmask = newVal(vecTy);
    XTIRInsn* vic = [[XTIRInsn alloc] initWithOpcode:XTIROpVICmp
                                              result:vmask
                                            operands:@[ cmpOperand(c.cmpInsn.operands[0]), cmpOperand(c.cmpInsn.operands[1]) ]
                                           predicate:c.cmpInsn.predicate
                                              dbgLoc:nil];
    [nb addObject:vic];
    XTIRValue* vinc = newVal(vecTy);
    [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVAnd
                                            result:vinc
                                          operands:@[ [XTIROperand useWithValueId:vmask.valueId], phSplat(c.countDeltaOp) ]
                                            dbgLoc:nil]];
    // Climb the masked increments to the accumulator's width with uaddlp — the
    // same ladder the widening sum uses. Pairwise summing preserves a total, so
    // folding lanes together does not disturb a count.
    XTIRValue* curInc = vinc;
    XTIRType* curLane = elemLane;
    while (curLane.byteWidth < c.laneType.byteWidth)
        {
        XTIRType* nextLane = (curLane.byteWidth == 1) ? [XTIRType u16Type] : [XTIRType u32Type];
        XTIRValue* w = newVal([XTIRType vecWithLane:nextLane]);
        [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVAddLP
                                                result:w
                                              operands:@[ [XTIROperand useWithValueId:curInc.valueId] ]
                                                dbgLoc:nil]];
        curInc = w;
        curLane = nextLane;
        }
    XTIRValue* vnext = newVal(accVecTy);
    [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVAdd
                                            result:vnext
                                          operands:@[ [XTIROperand useWithValueId:vacc.valueId], [XTIROperand useWithValueId:curInc.valueId] ]
                                            dbgLoc:nil]];
    [B.instructions setArray:nb];

    // Re-step the iv by the vector width (in the latch L).
    NSMutableArray<XTIROperand*>* ivOps = [c.ivNext.operands mutableCopy];
    for (NSUInteger k = 0; k < ivOps.count; k++)
        if (ivOps[k].kind == XTIROperandKindImmI || (ivOps[k].kind == XTIROperandKindUse && ivOps[k].valueId != c.ivId))
            ivOps[k] = [XTIROperand immIWithType:c.ivNext.result.type value:(int64_t)c.vw];
    [c.ivNext replaceOperands:ivOps];

    // Vector accumulator phi: splat(0) init, back-edge value vnext (defined in
    // B, dominates the latch L). Additive, so seed is added back at the exit.
    XTIRValue* vacc0 = newVal(accVecTy);
    XTIRValue* zero = newVal(c.laneType);
    [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                         result:zero
                                                       operands:@[ [XTIROperand immIWithType:c.laneType value:0] ]
                                                         dbgLoc:nil]];
    [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                         result:vacc0
                                                       operands:@[ [XTIROperand useWithValueId:zero.valueId] ]
                                                         dbgLoc:nil]];
    XTIRInsn* vphi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                               result:vacc
                                             operands:@[ [XTIROperand blockWithRef:PH], [XTIROperand useWithValueId:vacc0.valueId],
                                                         [XTIROperand blockWithRef:L], [XTIROperand useWithValueId:vnext.valueId] ]
                                               dbgLoc:nil];
    NSMutableArray<XTIRInsn*>* newPhis = [NSMutableArray array];
    for (XTIRInsn* phi in H.phiNodes)
        [newPhis addObject:(phi == c.accPhi ? vphi : phi)];
    [H.phiNodes setArray:newPhis];

    // Horizontal add at exit; add back a non-zero seed; rewire live-out.
    XTIRValue* red = newVal(c.laneType);
    XTIRInsn* rd = [[XTIRInsn alloc] initWithOpcode:XTIROpVReduceAdd
                                             result:red
                                           operands:@[ [XTIROperand useWithValueId:vacc.valueId] ]
                                             dbgLoc:nil];
    NSMutableArray<XTIRInsn*>* head = [@[ rd ] mutableCopy];
    XTIRValueId outId = red.valueId;
    int64_t sk = 0;
    NSMutableDictionary<NSNumber*, XTIRInsn*>* d2 = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                d2[@(i.result.valueId)] = i;
    if (!(resolveConstInt(c.seedOp, d2, &sk) && sk == 0))
        {
        XTIRValue* withSeed = newVal(c.laneType);
        [head addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                  result:withSeed
                                                operands:@[ [XTIROperand useWithValueId:red.valueId], c.seedOp ]
                                                  dbgLoc:nil]];
        outId = withSeed.valueId;
        }
    [E.instructions insertObjects:head atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, head.count)]];
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
            {
            if (insn == rd)
                continue;
            NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
            BOOL changed = NO;
            for (NSUInteger k = 0; k < ops.count; k++)
                if (ops[k].kind == XTIROperandKindUse && ops[k].valueId == c.accId)
                    {
                    ops[k] = [XTIROperand useWithValueId:outId];
                    changed = YES;
                    }
            if (changed)
                [insn replaceOperands:ops];
            }
        }
    }

// ── Multi-accumulator unroll of vectorised reduction loops ───────────────
//
// A vectorised reduction loop `H: vacc=phi; iv=phi; guard / B: …; vnext=Vop(vacc,X);
// iv+=vw; ->H` carries a SERIAL dependency through `vnext = Vop(vacc, …)` — each
// iteration waits for the previous add/max. Unrolling ×U with U independent
// accumulators (each summing every U-th vector) turns it into U parallel chains
// the out-of-order core overlaps, then combines them at the exit. Only the
// single-block-latch shape (H → B → H) is handled; others are left as-is.
- (void)unrollVectorReductionsInFunction:(XTIRFunction*)fn
    {
    for (NSUInteger hi = 0; hi < fn.blocks.count; hi++)
        {
        XTIRBlock* H = fn.blocks[hi];
        if (H.phiNodes.count != 2)
            continue;

        NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
        for (XTIRBlock* bb in fn.blocks)
            {
            for (XTIRInsn* p in bb.phiNodes)
                if (p.result)
                    {
                    defOf[@(p.result.valueId)] = p;
                    defBlk[@(p.result.valueId)] = bb;
                    }
            for (XTIRInsn* i in bb.instructions)
                if (i.result)
                    {
                    defOf[@(i.result.valueId)] = i;
                    defBlk[@(i.result.valueId)] = bb;
                    }
            }

        XTIRInsn *vaccPhi = nil, *ivPhi = nil;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.operands.count != 4)
                {
                vaccPhi = nil;
                break;
                }
            if (phi.result.type.kind == XTIRTypeKindVec)
                vaccPhi = phi;
            else
                ivPhi = phi;
            }
        if (!vaccPhi || !ivPhi)
            continue;
        XTIRValueId vaccId = vaccPhi.result.valueId, ivId = ivPhi.result.valueId;
        XTIRType* vecTy = vaccPhi.result.type;

        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || guard.operands.count < 2 ||
            guard.operands[0].kind != XTIROperandKindUse || guard.operands[0].valueId != ivId)
            continue;
        // The bound may be a literal, or the runtime limit M = n & ~(vw-1) that
        // the vectoriser builds for a runtime trip count (#1136). Both are
        // unrollable; which one it is decides how U is chosen, below.
        int64_t N = 0;
        BOOL constN = resolveConstInt(guard.operands[1], defOf, &N);
        if (constN && N <= 0)
            continue;

        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        BOOL (^isLatch)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b && b != H && b.phiNodes.count == 0 && b.terminator &&
                 b.terminator.opcode == XTIROpBranch && b.terminator.operands.count >= 1 &&
                 b.terminator.operands[0].blockRef == H;
        };
        XTIRBlock* B = isLatch(t0) ? t0 : (isLatch(t1) ? t1 : nil);
        XTIRBlock* E = (B == t0) ? t1 : t0;
        if (!B || !E)
            continue;

        // vnext = vacc back-edge: Vop(vacc, X); ivNext = Add(iv, vw); both in B.
        XTIROperand* vnextOp = (vaccPhi.operands[0].blockRef == B) ? vaccPhi.operands[1] : vaccPhi.operands[3];
        XTIROperand* ivNextOp = (ivPhi.operands[0].blockRef == B) ? ivPhi.operands[1] : ivPhi.operands[3];
        if (vnextOp.kind != XTIROperandKindUse || ivNextOp.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* vnextInsn = defOf[@(vnextOp.valueId)];
        XTIRInsn* ivNextInsn = defOf[@(ivNextOp.valueId)];
        if (!vnextInsn || defBlk[@(vnextOp.valueId)] != B)
            continue;
        if (!ivNextInsn || ivNextInsn.opcode != XTIROpAdd || defBlk[@(ivNextOp.valueId)] != B)
            continue;
        if (!(vnextInsn.opcode == XTIROpVAdd || vnextInsn.opcode == XTIROpVMax || vnextInsn.opcode == XTIROpVMin))
            continue;
        if (vnextInsn.operands.count < 2 ||
            vnextInsn.operands[0].kind != XTIROperandKindUse || vnextInsn.operands[1].kind != XTIROperandKindUse)
            continue;
        // vnext must be Vop(vacc, X) — one operand is the accumulator.
        if (vnextInsn.operands[0].valueId != vaccId && vnextInsn.operands[1].valueId != vaccId)
            continue;
        int64_t vw = 0;
        XTIROperand* stepOp = nil;
        if (ivNextInsn.operands[0].kind == XTIROperandKindUse && ivNextInsn.operands[0].valueId == ivId)
            stepOp = ivNextInsn.operands[1];
        else if (ivNextInsn.operands[1].kind == XTIROperandKindUse && ivNextInsn.operands[1].valueId == ivId)
            stepOp = ivNextInsn.operands[0];
        if (!stepOp || !resolveConstInt(stepOp, defOf, &vw) || vw < 2)
            continue;

        // Preheader init: vacc's non-B incoming is a VSplat we replicate per copy.
        XTIRBlock* PH = (vaccPhi.operands[0].blockRef == B) ? vaccPhi.operands[2].blockRef : vaccPhi.operands[0].blockRef;
        XTIROperand* initOp = (vaccPhi.operands[0].blockRef == B) ? vaccPhi.operands[3] : vaccPhi.operands[1];
        if (!PH || initOp.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* initInsn = defOf[@(initOp.valueId)];
        if (!initInsn || initInsn.opcode != XTIROpVSplat || defBlk[@(initOp.valueId)] != PH)
            continue;

        NSInteger U;
        if (constN)
            {
            U = (N % (4 * vw) == 0) ? 4 : (N % (2 * vw) == 0 ? 2 : 1);
            }
        else
            {
            // A RUNTIME bound. The vectoriser emitted `M = n & ~(vw-1)`, and the
            // unroll needs the trip to be a whole number of U vectors -- so widen
            // that mask to ~(U*vw-1), and it is one by construction. Nothing else
            // has to change: the guard and the scalar clone's induction seed are
            // the SAME value, so lowering M moves both together, and the clone
            // already runs [M, n). The tail merely gets up to U*vw-1 elements
            // instead of vw-1, which on any loop worth vectorising is noise.
            //
            // Refused unless the mask is EXACTLY the one the vectoriser built:
            // any other bound is one this pass does not understand, and
            // rewriting it would change the loop's trip count.
            XTIRInsn* mask = (guard.operands[1].kind == XTIROperandKindUse)
                                 ? defOf[@(guard.operands[1].valueId)]
                                 : nil;
            if (!mask || mask.opcode != XTIROpAnd || mask.operands.count < 2)
                continue;
            if (mask.operands[1].kind != XTIROperandKindImmI)
                continue;
            if (mask.operands[1].intValue != ~((int64_t)vw - 1))
                continue;
            U = 4;
            NSMutableArray<XTIROperand*>* mops = [mask.operands mutableCopy];
            mops[1] = [XTIROperand immIWithType:mask.result.type
                                          value:~((int64_t)(U * vw) - 1)];
            [mask replaceOperands:mops];
            }
        if (U < 2)
            continue;

        XTIRValue* (^newVal)(XTIRType*) = ^XTIRValue*(XTIRType* ty) {
          XTIRValueId rid = [fn allocateValueId];
          XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                       type:ty
                                                    defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:0]];
          [fn registerValue:v];
          return v;
        };

        // iv-dependent body instructions (transitively use iv), in order, EXCEPT
        // the iv step (re-stepped to U*vw separately). vnextInsn is included
        // (it depends on X, which depends on iv).
        NSMutableSet<NSNumber*>* dep = [NSMutableSet setWithObject:@(ivId)];
        NSMutableArray<XTIRInsn*>* ivDep = [NSMutableArray array];
        for (XTIRInsn* insn in B.instructions)
            {
            if (insn == ivNextInsn)
                continue;
            BOOL d = NO;
            for (XTIROperand* o in insn.operands)
                if (o.kind == XTIROperandKindUse && [dep containsObject:@(o.valueId)])
                    {
                    d = YES;
                    break;
                    }
            if (d)
                {
                [ivDep addObject:insn];
                if (insn.result)
                    [dep addObject:@(insn.result.valueId)];
                }
            }

        // Build U-1 extra accumulators by cloning the iv-dependent chain with
        // iv → iv+k*vw and vacc → vacc_k.
        XTIRType* ivTy = ivNextInsn.result.type;
        NSMutableArray<XTIRInsn*>* appended = [NSMutableArray array];
        NSMutableArray<XTIRInsn*>* newPhis = [NSMutableArray array];
        NSMutableArray<NSNumber*>* accIds = [NSMutableArray arrayWithObject:@(vaccId)]; // copy 0 = original
        for (NSInteger k = 1; k < U; k++)
            {
            XTIRValue* vacc_k = newVal(vecTy);
            // All U accumulators start from the SAME preheader broadcast — reuse
            // copy 0's VSplat rather than cloning it per copy. U-1 phi copies
            // (movdqa/mov) replace U-1 live splats: the backends' vector
            // register pools hold 8, and U extra splats on top of the U
            // accumulators is how the pool overflowed (#1198).
            XTIRValue* iv_k = newVal(ivTy);
            [appended addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                          result:iv_k
                                                        operands:@[ [XTIROperand useWithValueId:ivId], [XTIROperand immIWithType:ivTy value:k * vw] ]
                                                          dbgLoc:nil]];
            NSMutableDictionary<NSNumber*, NSNumber*>* remap = [NSMutableDictionary dictionary];
            remap[@(ivId)] = @(iv_k.valueId);
            remap[@(vaccId)] = @(vacc_k.valueId);
            XTIRValueId vnext_k = 0;
            for (XTIRInsn* insn in ivDep)
                {
                NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
                for (XTIROperand* o in insn.operands)
                    {
                    if (o.kind == XTIROperandKindUse && remap[@(o.valueId)])
                        [ops addObject:[XTIROperand useWithValueId:remap[@(o.valueId)].unsignedIntegerValue]];
                    else
                        [ops addObject:o];
                    }
                XTIRValue* r = insn.result ? newVal(insn.result.type) : nil;
                XTIRInsn* clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                                            result:r
                                                          operands:ops
                                                         predicate:insn.predicate
                                                            dbgLoc:insn.dbgLoc];
                if (insn.memoryResult)
                    clone.memoryResult = newVal([XTIRType memoryType]);
                if (r)
                    remap[@(insn.result.valueId)] = @(r.valueId);
                [appended addObject:clone];
                if (insn == vnextInsn)
                    vnext_k = r.valueId;
                }
            [newPhis addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                         result:vacc_k
                                                       operands:@[ [XTIROperand blockWithRef:PH], [XTIROperand useWithValueId:initOp.valueId],
                                                                   [XTIROperand blockWithRef:B], [XTIROperand useWithValueId:vnext_k] ]
                                                         dbgLoc:nil]];
            [accIds addObject:@(vacc_k.valueId)];
            }

        // Append the clones at the END of B (after copy-0's full chain), so the
        // loop-invariant values copy-0 computes mid-body (e.g. the count splats)
        // are defined before the clones that share them. The iv step is also in
        // B but order-independent (it reads only the iv phi).
        [B.instructions addObjectsFromArray:appended];
        NSMutableArray<XTIROperand*>* ivOps = [ivNextInsn.operands mutableCopy];
        for (NSUInteger j = 0; j < ivOps.count; j++)
            if (ivOps[j].kind == XTIROperandKindImmI || (ivOps[j].kind == XTIROperandKindUse && ivOps[j].valueId != ivId))
                ivOps[j] = [XTIROperand immIWithType:ivTy value:U * vw];
        [ivNextInsn replaceOperands:ivOps];

        for (XTIRInsn* p in newPhis)
            [H.phiNodes addObject:p];

        // Combine the U accumulators at the exit (same op as the reduction),
        // then point the existing reduce at the combined accumulator.
        NSMutableArray<XTIRInsn*>* combine = [NSMutableArray array];
        XTIRValueId cur = vaccId;
        for (NSInteger k = 1; k < U; k++)
            {
            XTIRValue* r = newVal(vecTy);
            [combine addObject:[[XTIRInsn alloc] initWithOpcode:vnextInsn.opcode
                                                         result:r
                                                       operands:@[ [XTIROperand useWithValueId:cur], [XTIROperand useWithValueId:accIds[k].unsignedIntegerValue] ]
                                                         dbgLoc:nil]];
            cur = r.valueId;
            }
        [E.instructions insertObjects:combine atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, combine.count)]];
        // Rewrite uses of the original accumulator outside H/B (the reduce) to
        // the combined value — but not inside the combine chain we just built.
        NSSet<XTIRInsn*>* combineSet = [NSSet setWithArray:combine];
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            for (XTIRInsn* insn in bb.instructions)
                {
                if ([combineSet containsObject:insn])
                    continue;
                NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
                BOOL changed = NO;
                for (NSUInteger j = 0; j < ops.count; j++)
                    if (ops[j].kind == XTIROperandKindUse && ops[j].valueId == vaccId)
                        {
                        ops[j] = [XTIROperand useWithValueId:cur];
                        changed = YES;
                        }
                if (changed)
                    [insn replaceOperands:ops];
                }
            }
        }
    }

// ── Widening sum reduction (u8/u16 → u32) ────────────────────────────────
//
// `acc:u32 += (u32)a[i]` over a u8/u16 array can't accumulate in narrow lanes
// (the sum overflows a byte/short), so we vector-load 16×u8 / 8×u16, fold the
// lanes up to u32 with `uaddlp` widening, accumulate into a 4×u32 vector, and
// horizontally reduce at the exit (sound: addition mod 2^32 is associative /
// commutative, so the lane regrouping matches the scalar wraparound sum). The
// accumulator update stays a VAdd, so the multi-accumulator unroller then
// unrolls it like any other add reduction.
// Dot product: `acc:u32/i32 += (u32)(a[i]*b[i])` over two u8/u16 arrays. Same
// shape as the widening sum, but the accumulated element is a product of two
// iv-indexed narrow loads (multiplied in the narrow lane, so it wraps exactly
// like the scalar u16*u16). Reuses applyWideningSum with a VMul inserted.
- (nullable XTVecCand*)recogniseDotProduct:(XTIRFunction*)fn
    {
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

    for (XTIRBlock* H in fn.blocks)
        {
        if (H.phiNodes.count != 2)
            continue;
        BOOL headerPure = YES;
        for (XTIRInsn* insn in H.instructions)
            if (insn.memoryResult)
                {
                headerPure = NO;
                break;
                }
        if (!headerPure)
            continue;

        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || guard.operands.count < 2 ||
            guard.operands[0].kind != XTIROperandKindUse || defBlk[@(term.operands[0].valueId)] != H)
            continue;
        XTIRValueId ivId = guard.operands[0].valueId;
        XTIRInsn *ivPhi = nil, *accPhi = nil;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.memoryResult || phi.operands.count != 4)
                {
                ivPhi = nil;
                break;
                }
            if (phi.result.valueId == ivId)
                ivPhi = phi;
            else
                accPhi = phi;
            }
        if (!ivPhi || !accPhi)
            continue;
        XTIRTypeKind ak = accPhi.result.type.kind;
        if (ak != XTIRTypeKindU32 && ak != XTIRTypeKindI32)
            continue;
        XTIRValueId accId = accPhi.result.valueId;
        int64_t N = 0;
        // A literal, or a RUNTIME bound. Accepted only when loop-INVARIANT
        // (checked below, once the body block is known) and the guard is a
        // strict `<`: with `i <= n` the trip is n+1 and n & ~(vw-1) is wrong.
        BOOL constBound = resolveConstInt(guard.operands[1], defOf, &N);
        BOOL runtimeTrip = NO;
        if (!constBound)
            {
            if (guard.operands[1].kind != XTIROperandKindUse)
                continue;
            if (!(guard.predicate == XTIRICmpULT || guard.predicate == XTIRICmpSLT))
                continue;
            runtimeTrip = YES;
            }
        else if (N <= 0)
            continue;

        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        BOOL (^latch)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b && b != H && b.phiNodes.count == 0 && b.terminator &&
                 b.terminator.opcode == XTIROpBranch && b.terminator.operands.count >= 1 &&
                 b.terminator.operands[0].blockRef == H;
        };
        XTIRBlock* B = latch(t0) ? t0 : (latch(t1) ? t1 : nil);
        XTIRBlock* E = (B == t0) ? t1 : t0;
        if (!B || !E || B.instructions.count == 0 || E.phiNodes.count != 0)
            continue;

        // accNext = Add(acc, ZExt(Mul(loadA, loadB))), in B, used once.
        XTIROperand* accBack = (accPhi.operands[0].blockRef == B) ? accPhi.operands[1] : accPhi.operands[3];
        if (accBack.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* accNext = defOf[@(accBack.valueId)];
        if (!accNext || accNext.opcode != XTIROpAdd || defBlk[@(accBack.valueId)] != B ||
            [uses countForObject:@(accBack.valueId)] != 1)
            continue;
        XTIROperand* elemOp = nil;
        if (accNext.operands[0].kind == XTIROperandKindUse && accNext.operands[0].valueId == accId)
            elemOp = accNext.operands[1];
        else if (accNext.operands[1].kind == XTIROperandKindUse && accNext.operands[1].valueId == accId)
            elemOp = accNext.operands[0];
        if (!elemOp || elemOp.kind != XTIROperandKindUse)
            continue;
        // elem = ZExt(prod); prod = Mul(loadA, loadB), narrow lane, in B.
        XTIRInsn* zx = defOf[@(elemOp.valueId)];
        if (!zx || zx.opcode != XTIROpZExt || defBlk[@(elemOp.valueId)] != B ||
            zx.operands.count < 1 || zx.operands[0].kind != XTIROperandKindUse)
            continue;
        if ([uses countForObject:@(elemOp.valueId)] != 1)
            continue;
        XTIRInsn* mul = defOf[@(zx.operands[0].valueId)];
        if (!mul || mul.opcode != XTIROpMul || defBlk[@(zx.operands[0].valueId)] != B ||
            [uses countForObject:@(zx.operands[0].valueId)] != 1 || mul.operands.count < 2 ||
            mul.operands[0].kind != XTIROperandKindUse || mul.operands[1].kind != XTIROperandKindUse)
            continue;

        // Both mul operands are iv-indexed narrow loads of the SAME lane type,
        // each used once (only by the mul); their loads feed nothing else.
        XTIRInsn* (^ivLoad)(XTIRValueId) = ^XTIRInsn*(XTIRValueId vid) {
          XTIRInsn* ld = defOf[@(vid)];
          if (!ld || ld.opcode != XTIROpLoad || !ld.result || defBlk[@(vid)] != B ||
              [uses countForObject:@(vid)] != 1 || ld.operands.count < 1 ||
              ld.operands[0].kind != XTIROperandKindUse)
              return nil;
          XTIRType* lt = ld.result.type;
          if (!lt || lt.kind != XTIRTypeKindU16)
              return nil; // VMul has no 8-bit-lane form
          XTIRInsn* ea = defOf[@(ld.operands[0].valueId)];
          if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count < 2 ||
              ea.operands[1].kind != XTIROperandKindUse || ea.operands[1].valueId != ivId)
              return nil;
          return ld;
        };
        XTIRInsn* loadA = ivLoad(mul.operands[0].valueId);
        XTIRInsn* loadB = ivLoad(mul.operands[1].valueId);
        if (!loadA || !loadB || loadA == loadB)
            continue;
        if (loadA.result.type.kind != loadB.result.type.kind)
            continue;
        XTIRType* lt = loadA.result.type;

        // ivNext = Add(iv,1) in B, the iv phi's back-edge.
        XTIRInsn* ivNext = nil;
        for (XTIRInsn* insn in B.instructions)
            if (insn.opcode == XTIROpAdd && insn.result && insn != accNext)
                {
                int64_t one = 0;
                XTIROperand* so = nil;
                if (insn.operands[0].kind == XTIROperandKindUse && insn.operands[0].valueId == ivId)
                    so = insn.operands[1];
                else if (insn.operands[1].kind == XTIROperandKindUse && insn.operands[1].valueId == ivId)
                    so = insn.operands[0];
                if (so && resolveConstInt(so, defOf, &one) && one == 1)
                    {
                    ivNext = insn;
                    break;
                    }
                }
        if (!ivNext)
            continue;
        XTIROperand* ivBack = (ivPhi.operands[0].blockRef == B) ? ivPhi.operands[1] : ivPhi.operands[3];
        if (ivBack.kind != XTIROperandKindUse || ivBack.valueId != ivNext.result.valueId)
            continue;

        // Body must be exactly the recognised shape (2 addresses + 2 loads + mul +
        // ZExt + the two Adds + constants) — no other side effects / arith.
        BOOL ok = YES;
        for (XTIRInsn* insn in B.instructions)
            {
            if (insn == accNext || insn == ivNext || insn == zx || insn == mul ||
                insn == loadA || insn == loadB)
                continue;
            XTIROpcode op = insn.opcode;
            if (op == XTIROpAddrOf || op == XTIROpElementAddr || op == XTIROpConst ||
                op == XTIROpZExt || op == XTIROpSExt || op == XTIROpTrunc)
                continue;
            ok = NO;
            break;
            }
        if (!ok)
            continue;
        // acc used in the loop only by accNext; iv must not escape H/B.
        for (XTIRBlock* bb in @[ H, B ])
            {
            for (XTIRInsn* u in bb.instructions)
                {
                if (u == accNext)
                    continue;
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == accId)
                        {
                        ok = NO;
                        break;
                        }
                if (!ok)
                    break;
                }
            if (!ok)
                break;
            }
        if (!ok)
            continue;
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            for (XTIRInsn* u in bb.instructions)
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == ivId)
                        {
                        ok = NO;
                        break;
                        }
            }
        if (!ok)
            continue;

        NSUInteger vw = 16 / lt.byteWidth;
        if (vw < 2)
            continue;
        // A non-zero start is VECTORISED, not refused: the epilogue below works
        // from the trip LENGTH, so [ivStart, N) splits into whole vectors plus a
        // scalar tail exactly as [0, N) does.
        //
        // The zero test used to double as what stopped the REMAINDER being
        // re-recognised and re-cloned — the clone's iv enters at M, so it failed
        // by construction. That job now belongs to the `< vw` test below, which
        // is the honest statement of it: a range with no whole vector in it is
        // not vectorisable, whatever it starts at.
        int64_t ivStart = 0;
        if (!xtvIvStartConst(ivPhi, B, defOf, &ivStart))
            continue;
        // N is only meaningful when the bound is a CONSTANT — with a runtime
        // trip it is still 0, so an unguarded `ivStart >= N` refuses every
        // runtime-bound loop, including the zero-start ones that vectorised
        // before. That is how this first showed up: the self-hosted optimiser
        // stopped vectorising vectorize_map_tail while the reference still did.
        if (!runtimeTrip && ivStart >= N)
            continue;
        // Not a whole number of vectors: the vector loop runs to the last whole
        // one and a CLONE finishes the tail (see applyWideningSum). A RUNTIME
        // bound always takes that path, and must be loop-INVARIANT: a value with
        // no defining instruction is a parameter, invariant by construction, so
        // an absent defBlk entry must NOT read as a refusal.
        if (runtimeTrip)
            {
            XTIRBlock* bdb = defBlk[@(guard.operands[1].valueId)];
            if (bdb == H || bdb == B)
                continue;
            }
        int64_t trip_ = N - ivStart;
        int64_t epiM_ = ivStart + (trip_ - (trip_ % (int64_t)vw));
        // Under one whole vector: stay scalar — and this is what refuses the
        // epilogue CLONE, which is shorter than a vector by construction.
        if (!runtimeTrip && (epiM_ - ivStart) < (int64_t)vw)
            continue;

        // Preheader (the header pred that is not the latch) and the accumulator seed.
        XTIRBlock* PH = nil;
        for (XTIRBlock* bb in fn.blocks)
            if (bb != B && bb.terminator)
                for (XTIROperand* o in bb.terminator.operands)
                    if (o.kind == XTIROperandKindBlock && o.blockRef == H)
                        {
                        PH = bb;
                        break;
                        }
        if (!PH)
            continue;
        XTIROperand* seedOp = (accPhi.operands[0].blockRef == B) ? accPhi.operands[3] : accPhi.operands[1];

        XTVecCand* c = [XTVecCand new];
        c.H = H;
        c.B = B;
        c.E = E;
        c.preheader = PH;
        c.ivPhi = ivPhi;
        c.ivNext = ivNext;
        c.guard = guard;
        c.ivId = ivId;
        c.accPhi = accPhi;
        c.accNext = accNext;
        c.accId = accId;
        c.seedOp = seedOp;
        c.isDotProduct = YES;
        c.loadLaneType = lt;
        c.vw = vw;
        c.loadId = loadA.result.valueId;
        c.loadId2 = loadB.result.valueId;
        c.epiN = N;
        c.epiM = epiM_;
        c.needsEpilogue = (runtimeTrip || epiM_ != N);
        c.runtimeTrip = runtimeTrip;
        c.boundOp = guard.operands[1];
        c.ivStart = ivStart;
        return c;
        }
    return nil;
    }

- (nullable XTVecCand*)recogniseWideningSum:(XTIRFunction*)fn
    {
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

    for (XTIRBlock* H in fn.blocks)
        {
        if (H.phiNodes.count != 2)
            continue;
        BOOL headerPure = YES;
        for (XTIRInsn* insn in H.instructions)
            if (insn.memoryResult)
                {
                headerPure = NO;
                break;
                }
        if (!headerPure)
            continue;

        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || guard.operands.count < 2 ||
            guard.operands[0].kind != XTIROperandKindUse || defBlk[@(term.operands[0].valueId)] != H)
            continue;
        XTIRValueId ivId = guard.operands[0].valueId;
        XTIRInsn *ivPhi = nil, *accPhi = nil;
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.memoryResult || phi.operands.count != 4)
                {
                ivPhi = nil;
                break;
                }
            if (phi.result.valueId == ivId)
                ivPhi = phi;
            else
                accPhi = phi;
            }
        if (!ivPhi || !accPhi || accPhi.result.type.kind != XTIRTypeKindU32)
            continue;
        XTIRValueId accId = accPhi.result.valueId;
        int64_t N = 0;
        // A literal, or a RUNTIME bound. Accepted only when loop-INVARIANT
        // (checked below, once the body block is known) and the guard is a
        // strict `<`: with `i <= n` the trip is n+1 and n & ~(vw-1) is wrong.
        BOOL constBound = resolveConstInt(guard.operands[1], defOf, &N);
        BOOL runtimeTrip = NO;
        if (!constBound)
            {
            if (guard.operands[1].kind != XTIROperandKindUse)
                continue;
            if (!(guard.predicate == XTIRICmpULT || guard.predicate == XTIRICmpSLT))
                continue;
            runtimeTrip = YES;
            }
        else if (N <= 0)
            continue;

        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        BOOL (^latch)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b && b != H && b.phiNodes.count == 0 && b.terminator &&
                 b.terminator.opcode == XTIROpBranch && b.terminator.operands.count >= 1 &&
                 b.terminator.operands[0].blockRef == H;
        };
        XTIRBlock* B = latch(t0) ? t0 : (latch(t1) ? t1 : nil);
        XTIRBlock* E = (B == t0) ? t1 : t0;
        if (!B || !E || B.instructions.count == 0 || E.phiNodes.count != 0)
            continue;

        // accNext = acc back-edge = Add(acc, elem), in B, used once.
        XTIROperand* accBack = (accPhi.operands[0].blockRef == B) ? accPhi.operands[1] : accPhi.operands[3];
        if (accBack.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* accNext = defOf[@(accBack.valueId)];
        if (!accNext || accNext.opcode != XTIROpAdd || defBlk[@(accBack.valueId)] != B ||
            [uses countForObject:@(accBack.valueId)] != 1)
            continue;
        XTIROperand* elemOp = nil;
        if (accNext.operands[0].kind == XTIROperandKindUse && accNext.operands[0].valueId == accId)
            elemOp = accNext.operands[1];
        else if (accNext.operands[1].kind == XTIROperandKindUse && accNext.operands[1].valueId == accId)
            elemOp = accNext.operands[0];
        if (!elemOp || elemOp.kind != XTIROperandKindUse)
            continue;
        // elem = ZExt(load) — unsigned widening of a u8/u16 iv-indexed load.
        XTIRInsn* zx = defOf[@(elemOp.valueId)];
        if (!zx || zx.opcode != XTIROpZExt || defBlk[@(elemOp.valueId)] != B ||
            zx.operands.count < 1 || zx.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* load = defOf[@(zx.operands[0].valueId)];
        if (!load || load.opcode != XTIROpLoad || !load.result || defBlk[@(load.result.valueId)] != B ||
            load.operands.count < 1 || load.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRType* lt = load.result.type;
        if (!lt || !(lt.kind == XTIRTypeKindU8 || lt.kind == XTIRTypeKindU16))
            continue;
        XTIRInsn* ea = defOf[@(load.operands[0].valueId)];
        if (!ea || ea.opcode != XTIROpElementAddr || ea.operands.count < 2 ||
            ea.operands[1].kind != XTIROperandKindUse || ea.operands[1].valueId != ivId)
            continue;
        // The ZExt feeds only the accumulator; the load feeds only the ZExt.
        if ([uses countForObject:@(elemOp.valueId)] != 1 || [uses countForObject:@(load.result.valueId)] != 1)
            continue;

        // ivNext = Add(iv,1) in B, the iv phi's back-edge.
        XTIRInsn* ivNext = nil;
        for (XTIRInsn* insn in B.instructions)
            if (insn.opcode == XTIROpAdd && insn.result && insn != accNext)
                {
                int64_t one = 0;
                XTIROperand* so = nil;
                if (insn.operands[0].kind == XTIROperandKindUse && insn.operands[0].valueId == ivId)
                    so = insn.operands[1];
                else if (insn.operands[1].kind == XTIROperandKindUse && insn.operands[1].valueId == ivId)
                    so = insn.operands[0];
                if (so && resolveConstInt(so, defOf, &one) && one == 1)
                    {
                    ivNext = insn;
                    break;
                    }
                }
        if (!ivNext)
            continue;
        XTIROperand* ivBack = (ivPhi.operands[0].blockRef == B) ? ivPhi.operands[1] : ivPhi.operands[3];
        if (ivBack.kind != XTIROperandKindUse || ivBack.valueId != ivNext.result.valueId)
            continue;

        // Body must be exactly the recognised shape (address + narrow load +
        // ZExt + the two Adds + constants) — no other side effects / arith.
        BOOL ok = YES;
        for (XTIRInsn* insn in B.instructions)
            {
            if (insn == accNext || insn == ivNext || insn == zx || insn == load)
                continue;
            XTIROpcode op = insn.opcode;
            if (op == XTIROpAddrOf || op == XTIROpElementAddr || op == XTIROpConst ||
                op == XTIROpZExt || op == XTIROpSExt || op == XTIROpTrunc)
                continue;
            ok = NO;
            break;
            }
        if (!ok)
            continue;
        // acc used in the loop only by accNext; iv must not escape H/B.
        for (XTIRBlock* bb in @[ H, B ])
            {
            for (XTIRInsn* u in bb.instructions)
                {
                if (u == accNext)
                    continue;
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == accId)
                        {
                        ok = NO;
                        break;
                        }
                if (!ok)
                    break;
                }
            if (!ok)
                break;
            }
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || bb == B)
                continue;
            for (XTIRInsn* u in bb.instructions)
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == ivId)
                        {
                        ok = NO;
                        break;
                        }
            }
        if (!ok)
            continue;

        NSUInteger vw = 16 / lt.byteWidth; // 16 (u8) or 8 (u16) per iter
        if (vw < 2)
            continue;
        // A non-zero start is VECTORISED, not refused: the epilogue below works
        // from the trip LENGTH, so [ivStart, N) splits into whole vectors plus a
        // scalar tail exactly as [0, N) does.
        //
        // The zero test used to double as what stopped the REMAINDER being
        // re-recognised and re-cloned — the clone's iv enters at M, so it failed
        // by construction. That job now belongs to the `< vw` test below, which
        // is the honest statement of it: a range with no whole vector in it is
        // not vectorisable, whatever it starts at.
        int64_t ivStart = 0;
        if (!xtvIvStartConst(ivPhi, B, defOf, &ivStart))
            continue;
        // N is only meaningful when the bound is a CONSTANT — with a runtime
        // trip it is still 0, so an unguarded `ivStart >= N` refuses every
        // runtime-bound loop, including the zero-start ones that vectorised
        // before. That is how this first showed up: the self-hosted optimiser
        // stopped vectorising vectorize_map_tail while the reference still did.
        if (!runtimeTrip && ivStart >= N)
            continue;
        // Not a whole number of vectors: the vector loop runs to the last whole
        // one and a CLONE finishes the tail (see applyWideningSum). A RUNTIME
        // bound always takes that path, and must be loop-INVARIANT: a value with
        // no defining instruction is a parameter, invariant by construction, so
        // an absent defBlk entry must NOT read as a refusal.
        if (runtimeTrip)
            {
            XTIRBlock* bdb = defBlk[@(guard.operands[1].valueId)];
            if (bdb == H || bdb == B)
                continue;
            }
        int64_t trip_ = N - ivStart;
        int64_t epiM_ = ivStart + (trip_ - (trip_ % (int64_t)vw));
        // Under one whole vector: stay scalar — and this is what refuses the
        // epilogue CLONE, which is shorter than a vector by construction.
        if (!runtimeTrip && (epiM_ - ivStart) < (int64_t)vw)
            continue;

        XTIROperand* seedOp = (accPhi.operands[0].blockRef == B) ? accPhi.operands[3] : accPhi.operands[1];
        XTVecCand* c = [XTVecCand new];
        c.H = H;
        c.B = B;
        c.E = E;
        c.ivPhi = ivPhi;
        c.ivNext = ivNext;
        c.guard = guard;
        c.ivId = ivId;
        c.laneType = [XTIRType u32Type];
        c.vw = vw;
        c.accPhi = accPhi;
        c.accId = accId;
        c.accNext = accNext;
        c.seedOp = seedOp;
        c.preheader = (accPhi.operands[0].blockRef == B) ? accPhi.operands[2].blockRef : accPhi.operands[0].blockRef;
        c.isWideningSum = YES;
        c.loadLaneType = lt;
        c.loadId = load.result.valueId;
        c.epiN = N;
        c.epiM = epiM_;
        c.needsEpilogue = (runtimeTrip || epiM_ != N);
        c.runtimeTrip = runtimeTrip;
        c.boundOp = guard.operands[1];
        c.ivStart = ivStart;
        return c;
        }
    return nil;
    }

- (void)applyWideningSum:(XTVecCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock *B = c.B, *H = c.H, *E = c.E, *PH = c.preheader;

    // Epilogue, part 1: clone the scalar loop BEFORE the body and the header's
    // phis are rewritten in place. Shared by the widening-sum and dot-product
    // recognisers, both of which consume 16 (u8) or 8 (u16) elements per vector,
    // so a non-multiple trip is the COMMON case for them rather than the rare one.
    XTIRBlock *H2 = nil, *B2 = nil;
    NSMutableDictionary<NSNumber*, NSNumber*>* cmap = [NSMutableDictionary dictionary];
    XTIRValueId runtimeMId = 0; // the computed vector limit, when the trip is runtime
    if (c.needsEpilogue)
        {
        xtvCloneLoop(fn, H, B, &H2, &B2, cmap);
        NSMutableArray<XTIROperand*>* gops = [c.guard.operands mutableCopy];
        if (c.runtimeTrip)
            {
            XTIRValueId mid = xtvEmitRuntimeM(fn, PH, c.boundOp, c.ivStart,
                                              c.vw, c.ivPhi.result.type);
            runtimeMId = mid;
            gops[1] = [XTIROperand useWithValueId:mid];
            }
        else
            {
            gops[1] = [XTIROperand immIWithType:c.ivPhi.result.type value:c.epiM];
            }
        [c.guard replaceOperands:gops];
        }
    XTIRType* u32 = [XTIRType u32Type];
    XTIRType* accVecTy = [XTIRType vecWithLane:u32];
    XTIRType* loadVecTy = [XTIRType vecWithLane:c.loadLaneType];
    XTIRValue* (^newVal)(XTIRType*) = ^XTIRValue*(XTIRType* ty) {
      XTIRValueId rid = [fn allocateValueId];
      XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                   type:ty
                                                defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:0]];
      [fn registerValue:v];
      return v;
    };

    // For a dot product the accumulated element is ZExt(Mul(loadA, loadB)); find
    // the scalar Mul so it (and its ZExt) can be replaced by a VMul of the two
    // vector loads. The ZExt to drop widens the mul result (dot) or the load
    // directly (plain widening sum).
    BOOL isDot = c.isDotProduct;
    XTIRValueId mulId = 0;
    if (isDot)
        for (XTIRInsn* insn in B.instructions)
            if (insn.opcode == XTIROpMul && insn.result && insn.operands.count >= 2 &&
                insn.operands[0].kind == XTIROperandKindUse && insn.operands[1].kind == XTIROperandKindUse &&
                ((insn.operands[0].valueId == c.loadId && insn.operands[1].valueId == c.loadId2) ||
                 (insn.operands[0].valueId == c.loadId2 && insn.operands[1].valueId == c.loadId)))
                {
                mulId = insn.result.valueId;
                break;
                }
    XTIRValueId zxSrc = isDot ? mulId : c.loadId;

    XTIRValue* vacc = newVal(accVecTy);
    NSMutableArray<XTIRInsn*>* nb = [NSMutableArray array];
    XTIRValue *vload = nil, *vload2 = nil;
    for (XTIRInsn* insn in B.instructions)
        {
        if (insn == c.accNext)
            continue; // scalar accumulate (replaced)
        if (isDot && insn.result && insn.result.valueId == mulId)
            continue; // scalar mul → VMul
        if (insn.result && (insn.result.valueId == c.loadId ||
                            (isDot && insn.result.valueId == c.loadId2)))
            {
            XTIRValue* vl = newVal(loadVecTy);
            XTIRInsn* vi = [[XTIRInsn alloc] initWithOpcode:XTIROpVLoad
                                                     result:vl
                                                   operands:insn.operands
                                                     dbgLoc:insn.dbgLoc];
            vi.memoryResult = insn.memoryResult;
            [nb addObject:vi];
            if (insn.result.valueId == c.loadId)
                vload = vl;
            else
                vload2 = vl;
            continue;
            }
        if (insn.opcode == XTIROpZExt && insn.operands.count >= 1 &&
            insn.operands[0].kind == XTIROperandKindUse && insn.operands[0].valueId == zxSrc)
            continue;        // the widened element (replaced)
        [nb addObject:insn]; // address / iv-step / constants
        }
    // Dot product: multiply the two loaded vectors in the narrow lane first
    // (VMul = pmullw / mul.8h keeps the low half, so it wraps exactly like the
    // scalar u16*u16). Then widen the product up to u32 and accumulate.
    XTIRValue* cur = vload;
    if (isDot)
        {
        XTIRValue* vprod = newVal(loadVecTy);
        [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVMul
                                                result:vprod
                                              operands:@[ [XTIROperand useWithValueId:vload.valueId],
                                                          [XTIROperand useWithValueId:vload2.valueId] ]
                                                dbgLoc:nil]];
        cur = vprod;
        }
    // Widen the (product) lanes up to u32 with uaddlp, then accumulate.
    XTIRType* curLane = c.loadLaneType;
    while (curLane.byteWidth < 4)
        {
        XTIRType* nextLane = (curLane.byteWidth == 1) ? [XTIRType u16Type] : u32;
        XTIRValue* w = newVal([XTIRType vecWithLane:nextLane]);
        [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVAddLP
                                                result:w
                                              operands:@[ [XTIROperand useWithValueId:cur.valueId] ]
                                                dbgLoc:nil]];
        cur = w;
        curLane = nextLane;
        }
    XTIRValue* vnext = newVal(accVecTy);
    [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVAdd
                                            result:vnext
                                          operands:@[ [XTIROperand useWithValueId:vacc.valueId], [XTIROperand useWithValueId:cur.valueId] ]
                                            dbgLoc:nil]];
    [B.instructions setArray:nb];

    // Step the iv by the lane count (16 for u8, 8 for u16).
    NSMutableArray<XTIROperand*>* ivOps = [c.ivNext.operands mutableCopy];
    for (NSUInteger k = 0; k < ivOps.count; k++)
        if (ivOps[k].kind == XTIROperandKindImmI || (ivOps[k].kind == XTIROperandKindUse && ivOps[k].valueId != c.ivId))
            ivOps[k] = [XTIROperand immIWithType:c.ivNext.result.type value:(int64_t)c.vw];
    [c.ivNext replaceOperands:ivOps];

    // Vector accumulator phi: splat(0) init (additive, seed added back at exit).
    XTIRValue* vacc0 = newVal(accVecTy);
    XTIRValue* zero = newVal(u32);
    [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                         result:zero
                                                       operands:@[ [XTIROperand immIWithType:u32 value:0] ]
                                                         dbgLoc:nil]];
    [PH.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                         result:vacc0
                                                       operands:@[ [XTIROperand useWithValueId:zero.valueId] ]
                                                         dbgLoc:nil]];
    XTIRInsn* vphi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                               result:vacc
                                             operands:@[ [XTIROperand blockWithRef:PH], [XTIROperand useWithValueId:vacc0.valueId],
                                                         [XTIROperand blockWithRef:B], [XTIROperand useWithValueId:vnext.valueId] ]
                                               dbgLoc:nil];
    NSMutableArray<XTIRInsn*>* newPhis = [NSMutableArray array];
    for (XTIRInsn* phi in H.phiNodes)
        [newPhis addObject:(phi == c.accPhi ? vphi : phi)];
    [H.phiNodes setArray:newPhis];

    // Horizontal add at exit; add back a non-zero seed; rewire live-out.
    XTIRValue* red = newVal(u32);
    XTIRInsn* rd = [[XTIRInsn alloc] initWithOpcode:XTIROpVReduceAdd
                                             result:red
                                           operands:@[ [XTIROperand useWithValueId:vacc.valueId] ]
                                             dbgLoc:nil];
    NSMutableArray<XTIRInsn*>* head = [@[ rd ] mutableCopy];
    XTIRValueId outId = red.valueId;
    int64_t sk = 0;
    NSMutableDictionary<NSNumber*, XTIRInsn*>* d2 = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                d2[@(i.result.valueId)] = i;
    if (!(resolveConstInt(c.seedOp, d2, &sk) && sk == 0))
        {
        XTIRValue* withSeed = newVal(u32);
        [head addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                  result:withSeed
                                                operands:@[ [XTIROperand useWithValueId:red.valueId], c.seedOp ]
                                                  dbgLoc:nil]];
        outId = withSeed.valueId;
        }
    // Epilogue, part 2: the horizontal add lands in a landing pad between the
    // vector loop and the remainder, because the remainder's accumulator starts
    // FROM it -- and because ONE predecessor is what keeps the remainder's phis
    // well-formed when the loop is later rotated (see apply:, part 2, for the
    // bug that costs).
    XTIRValueId finalId = outId;
    if (c.needsEpilogue)
        {
        XTIRBlock* VE = [[XTIRBlock alloc] init];
        VE.name = [NSString stringWithFormat:@"%@_vexit", H.name ?: @"hdr"];
        for (XTIRInsn* i in head)
            [VE appendInstruction:i];
        [VE setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                    result:nil
                                                  operands:@[ [XTIROperand blockWithRef:H2] ]
                                                    dbgLoc:nil]];

        NSMutableArray<XTIROperand*>* tops = [H.terminator.operands mutableCopy];
        for (NSUInteger k = 0; k < tops.count; k++)
            if (tops[k].kind == XTIROperandKindBlock && tops[k].blockRef == E)
                tops[k] = [XTIROperand blockWithRef:VE];
        [H.terminator replaceOperands:tops];

        XTIRValueId ivCloneId = (XTIRValueId)cmap[@(c.ivPhi.result.valueId)].unsignedLongLongValue;
        XTIRValueId accCloneId = (XTIRValueId)cmap[@(c.accPhi.result.valueId)].unsignedLongLongValue;
        for (XTIRInsn* phi in H2.phiNodes)
            {
            NSMutableArray<XTIROperand*>* pops = [phi.operands mutableCopy];
            for (NSUInteger k = 0; k + 1 < pops.count; k += 2)
                {
                if (!(pops[k].kind == XTIROperandKindBlock && pops[k].blockRef == PH))
                    continue;
                pops[k] = [XTIROperand blockWithRef:VE];
                if (phi.result.valueId == ivCloneId)
                    pops[k + 1] = c.runtimeTrip
                                      ? [XTIROperand useWithValueId:runtimeMId]
                                      : [XTIROperand immIWithType:c.ivPhi.result.type value:c.epiM];
                else if (phi.result.valueId == accCloneId)
                    pops[k + 1] = [XTIROperand useWithValueId:outId];
                }
            [phi replaceOperands:pops];
            }
        finalId = accCloneId; // after the loop, read the REMAINDER's total

        NSUInteger at = [fn.blocks indexOfObjectIdenticalTo:B];
        [fn.blocks insertObjects:@[ VE, H2, B2 ]
                       atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(at + 1, 3)]];
        }
    else
        {
        [E.instructions insertObjects:head atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, head.count)]];
        }
    for (XTIRBlock* bb in fn.blocks)
        {
        // The clone reads the original accumulator id through its own remapped
        // values; rewriting inside it would point the remainder at its own result.
        if (bb == H || bb == B || bb == H2 || bb == B2)
            continue;
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
        [all addObjectsFromArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* insn in all)
            {
            if (insn == rd)
                continue;
            NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
            BOOL changed = NO;
            for (NSUInteger k = 0; k < ops.count; k++)
                if (ops[k].kind == XTIROperandKindUse && ops[k].valueId == c.accId)
                    {
                    ops[k] = [XTIROperand useWithValueId:finalId];
                    changed = YES;
                    }
            if (changed)
                [insn replaceOperands:ops];
            }
        }
    }

@end
