// XTIROptOuterUnroll.m — see the header. Mirrors selfhost/opt/OptOuterUnroll.xc
// step for step: the loops are found in the same order (a latch per block in
// function order, its successors in terminator order), and the copies create
// their values in the same order, which is what the back ends number frame
// slots by.
#import "XTIROptOuterUnroll.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSupport.h"
#import "XTIRDominators.h"

#define OU_KEY(b) [NSValue valueWithNonretainedObject:(b)]

@interface XTOULoop : NSObject
@property(nonatomic, weak) XTIRBlock* header;
@property(nonatomic, weak) XTIRBlock* latch;
@property(nonatomic, weak, nullable) XTIRBlock* pre;
@property(nonatomic, strong) NSMutableArray<XTIRBlock*>* body;
@end
@implementation XTOULoop
@end

@implementation XTIROptOuterUnroll

- (NSString*)passName
    {
    return @"outer-unroll";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

// Successors in terminator-operand order, a target named twice counted twice.
static NSArray<XTIRBlock*>* ouSuccs(XTIRBlock* bb)
    {
    NSMutableArray<XTIRBlock*>* s = [NSMutableArray array];
    for (XTIROperand* o in bb.terminator.operands)
        if (o.kind == XTIROperandKindBlock && o.blockRef)
            [s addObject:o.blockRef];
    return s;
    }

// Natural loops, one per back edge, as the port's lrcLoops finds them.
static NSArray<XTOULoop*>* ouLoops(XTIRFunction* fn)
    {
    XTIRDominators* dom = [XTIRDominators forFunction:fn];
    NSMutableArray<XTOULoop*>* loops = [NSMutableArray array];
    if (!dom)
        return loops;
    NSMutableDictionary<NSValue*, NSMutableArray<XTIRBlock*>*>* preds = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRBlock* s in ouSuccs(bb))
            {
            NSMutableArray* ps = preds[OU_KEY(s)];
            if (!ps)
                preds[OU_KEY(s)] = ps = [NSMutableArray array];
            [ps addObject:bb];
            }
    for (XTIRBlock* latch in fn.blocks)
        for (XTIRBlock* H in ouSuccs(latch))
            {
            if (![dom block:H dominates:latch])
                continue;
            XTOULoop* L = [[XTOULoop alloc] init];
            L.header = H;
            L.latch = latch;
            L.body = [NSMutableArray arrayWithObject:H];
            NSMutableSet<NSValue*>* in = [NSMutableSet setWithObject:OU_KEY(H)];
            NSMutableArray<XTIRBlock*>* wl = [NSMutableArray arrayWithObject:latch];
            while (wl.count)
                {
                XTIRBlock* n = wl.lastObject;
                [wl removeLastObject];
                if ([in containsObject:OU_KEY(n)])
                    continue;
                [L.body addObject:n];
                [in addObject:OU_KEY(n)];
                if (n == H)
                    continue;
                for (XTIRBlock* p in preds[OU_KEY(n)])
                    [wl addObject:p];
                }
            XTIRBlock* pre = nil;
            NSUInteger outside = 0;
            for (XTIRBlock* p in preds[OU_KEY(H)])
                {
                if ([in containsObject:OU_KEY(p)])
                    continue;
                outside++;
                pre = p;
                }
            L.pre = outside == 1 ? pre : nil;
            [loops addObject:L];
            }
    return loops;
    }

// A constant: an immediate, a Const, or a ZExt/SExt of one.
static BOOL ouConst(XTIROperand* o, NSDictionary<NSNumber*, XTIRInsn*>* defOf, int64_t* out, unsigned depth)
    {
    if (!o || depth > 3)
        return NO;
    if (o.kind == XTIROperandKindImmI)
        {
        *out = o.intValue;
        return YES;
        }
    if (o.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* d = defOf[@(o.valueId)];
    if (!d || d.operands.count < 1)
        return NO;
    if (d.opcode == XTIROpConst)
        {
        XTIROperand* c = d.operands[0];
        if (c.kind != XTIROperandKindImmI)
            return NO;
        *out = c.intValue;
        return YES;
        }
    if (d.opcode == XTIROpZExt || d.opcode == XTIROpSExt)
        return ouConst(d.operands[0], defOf, out, depth + 1);
    return NO;
    }

static XTIROperand* _Nullable ouIncoming(XTIRInsn* phi, XTIRBlock* from)
    {
    NSArray<XTIROperand*>* ops = phi.operands;
    for (NSUInteger k = 0; k + 1 < ops.count; k += 2)
        if (ops[k].blockRef == from)
            return ops[k + 1];
    return nil;
    }

static BOOL ouCallsOut(XTIROpcode op)
    {
    switch (op)
        {
        case XTIROpCall: case XTIROpCallIndirect: case XTIROpCallCloaked:
        case XTIROpCallBanked: case XTIROpCallBankedIndirect:
        case XTIROpVTblDispatch: case XTIROpProtoDispatch:
            return YES;
        default:
            return NO;
        }
    }

static NSDictionary<NSNumber*, XTIRInsn*>* ouDefMap(XTIRFunction* fn)
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result)
                defOf[@(p.result.valueId)] = p;
        for (XTIRInsn* n in bb.instructions)
            if (n.result)
                defOf[@(n.result.valueId)] = n;
        }
    return defOf;
    }

// Does one of the inner loop's exits compare a value the inner loop loads?
static BOOL ouDataExit(XTIRFunction* fn, NSSet<NSValue*>* inI, NSDictionary<NSNumber*, XTIRInsn*>* defOf)
    {
    NSMutableSet<NSNumber*>* loads = [NSMutableSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        if (![inI containsObject:OU_KEY(bb)])
            continue;
        for (XTIRInsn* n in bb.instructions)
            if (n.opcode == XTIROpLoad && n.result)
                [loads addObject:@(n.result.valueId)];
        }
    for (XTIRBlock* bb in fn.blocks)
        {
        if (![inI containsObject:OU_KEY(bb)])
            continue;
        XTIRInsn* t = bb.terminator;
        if (!t || t.opcode != XTIROpCondBranch || t.operands.count < 3)
            continue;
        BOOL exits = NO;
        for (NSUInteger k = 1; k < 3; k++)
            if (![inI containsObject:OU_KEY(t.operands[k].blockRef)])
                exits = YES;
        XTIROperand* c = t.operands[0];
        if (!exits || c.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* cmp = defOf[@(c.valueId)];
        if (!cmp || cmp.opcode != XTIROpICmp)
            continue;
        for (XTIROperand* o in cmp.operands)
            if (o.kind == XTIROperandKindUse && [loads containsObject:@(o.valueId)])
                return YES;
        }
    return NO;
    }

static NSString* ouUniqueBlockName(XTIRFunction* fn, NSString* want)
    {
    NSMutableSet<NSString*>* used = [NSMutableSet set];
    for (XTIRBlock* b in fn.blocks)
        if (b.name)
            [used addObject:b.name];
    if (![used containsObject:want])
        return want;
    for (NSUInteger n = 2; n < 10000; n++)
        {
        NSString* c = [NSString stringWithFormat:@"%@_%lu", want, (unsigned long)n];
        if (![used containsObject:c])
            return c;
        }
    return want;
    }

static XTIROperand* ouSubst(NSDictionary<NSNumber*, NSNumber*>* _Nullable vmap,
                            NSDictionary<NSValue*, XTIRBlock*>* _Nullable bmap, XTIROperand* o)
    {
    if (o.kind == XTIROperandKindBlock)
        {
        XTIRBlock* nb = bmap[OU_KEY(o.blockRef)];
        return nb ? [XTIROperand blockWithRef:nb] : o;
        }
    if (o.kind != XTIROperandKindUse)
        return o;
    NSNumber* n = vmap[@(o.valueId)];
    return n ? [XTIROperand useWithValueId:(XTIRValueId)n.unsignedLongLongValue] : o;
    }

// A fresh result (and memory result) for `n`, defined at `idx` of `into`.
static void ouNewResult(XTIRFunction* fn, NSMutableDictionary<NSNumber*, NSNumber*>* vmap,
                        XTIRInsn* n, XTIRBlock* into, NSUInteger idx)
    {
    if (n.result)
        {
        XTIRValueId rid = [fn allocateValueId];
        XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                     type:n.result.type
                                                  defSite:[[XTIRDefSite alloc] initWithBlock:into insnIndex:idx]];
        [fn registerValue:v];
        vmap[@(n.result.valueId)] = @(rid);
        }
    if (n.memoryResult)
        {
        XTIRValueId mid = [fn allocateValueId];
        XTIRValue* v = [[XTIRValue alloc] initWithValueId:mid
                                                     type:[XTIRType memoryType]
                                                  defSite:[[XTIRDefSite alloc] initWithBlock:into insnIndex:idx]];
        [fn registerValue:v];
        vmap[@(n.memoryResult.valueId)] = @(mid);
        }
    }

static XTIRInsn* ouClone(XTIRFunction* fn, XTIRInsn* n, NSDictionary<NSNumber*, NSNumber*>* vmap,
                         NSDictionary<NSValue*, XTIRBlock*>* bmap)
    {
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:n.operands.count];
    for (XTIROperand* o in n.operands)
        [ops addObject:ouSubst(vmap, bmap, o)];
    XTIRValue* res = n.result ? fn.values[vmap[@(n.result.valueId)]] : nil;
    XTIRValue* mem = n.memoryResult ? fn.values[vmap[@(n.memoryResult.valueId)]] : nil;
    XTIRInsn* cl;
    if (n.callConv)
        cl = [[XTIRInsn alloc] initWithOpcode:n.opcode result:res operands:ops callConv:n.callConv dbgLoc:n.dbgLoc];
    else if (XTIROpCarriesPredicate(n.opcode))
        cl = [[XTIRInsn alloc] initWithOpcode:n.opcode result:res operands:ops predicate:n.predicate dbgLoc:n.dbgLoc];
    else
        cl = [[XTIRInsn alloc] initWithOpcode:n.opcode result:res operands:ops dbgLoc:n.dbgLoc];
    cl.memoryResult = mem;
    return cl;
    }

- (BOOL)runOnModule:(XTIRModule*)mod errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    // NO from a pass means it FAILED and stops the pipeline, so this
    // returns YES whether or not it unrolled anything.
    (void)outErrors;
    if (!self.profile || !self.profile.unrollsOuterLoops)
        return YES;
    for (XTIRFunction* fn in mod.functions)
        {
        // One loop at a time, re-recognised from the live CFG. An unrolled
        // loop holds K inner loops and steps by more than one, so it never
        // matches again; the bound is a backstop.
        unsigned iter = 0;
        while (iter < 64 && [self unrollOneIn:fn])
            iter++;
        }
    return YES;
    }

- (BOOL)unrollOneIn:(XTIRFunction*)fn
    {
    NSArray<XTOULoop*>* loops = ouLoops(fn);
    for (XTOULoop* L in loops)
        if ([self tryLoop:L in:fn loops:loops])
            return YES;
    return NO;
    }

- (BOOL)tryLoop:(XTOULoop*)L in:(XTIRFunction*)fn loops:(NSArray<XTOULoop*>*)loops
    {
    XTIRBlock* B = L.header;
    XTIRBlock* Lt = L.latch;
    if (!L.pre || B == Lt)
        return NO;
    NSMutableSet<NSValue*>* inL = [NSMutableSet set];
    for (XTIRBlock* bb in L.body)
        [inL addObject:OU_KEY(bb)];
    // One back edge to B.
    NSUInteger sameHeader = 0;
    for (XTOULoop* K in loops)
        if (K.header == B)
            sameHeader++;
    if (sameHeader != 1)
        return NO;
    // The latch goes back to B on true and out to X on false.
    XTIRInsn* t = Lt.terminator;
    if (!t || t.opcode != XTIROpCondBranch || t.operands.count < 3)
        return NO;
    XTIROperand* tc = t.operands[0];
    XTIRBlock* X = t.operands[2].blockRef;
    if (tc.kind != XTIROperandKindUse || t.operands[1].blockRef != B || !X || [inL containsObject:OU_KEY(X)])
        return NO;
    // No other way out, no call, and a small body.
    NSUInteger size = 0;
    for (XTIRBlock* bb in L.body)
        {
        for (XTIRBlock* sb in ouSuccs(bb))
            if (![inL containsObject:OU_KEY(sb)] && !(bb == Lt && sb == X))
                return NO;
        size += bb.phiNodes.count + bb.instructions.count + 1;
        for (XTIRInsn* n in bb.instructions)
            if (ouCallsOut(n.opcode))
                return NO;
        }
    if (size > 64)
        return NO;
    // Exactly one inner loop, innermost.
    XTIRBlock* I = nil;
    for (XTOULoop* K in loops)
        {
        XTIRBlock* h = K.header;
        if (h == B || ![inL containsObject:OU_KEY(h)])
            continue;
        if (!I)
            I = h;
        else if (h != I)
            return NO;
        }
    if (!I)
        return NO;
    NSMutableSet<NSValue*>* inI = [NSMutableSet set];
    for (XTOULoop* K in loops)
        if (K.header == I)
            for (XTIRBlock* bb in K.body)
                [inI addObject:OU_KEY(bb)];
    if ([inI containsObject:OU_KEY(B)])
        return NO;
    NSDictionary<NSNumber*, XTIRInsn*>* defOf = ouDefMap(fn);
    if (!ouDataExit(fn, inI, defOf))
        return NO;
    // The trip: i from S, next = i + 1, the test next <> N.
    XTIRInsn* cmp = defOf[@(tc.valueId)];
    if (!cmp || cmp.opcode != XTIROpICmp || cmp.operands.count < 2)
        return NO;
    uint8_t p = cmp.predicate;
    if (!(p == XTIRICmpULT || p == XTIRICmpSLT || p == XTIRICmpNE))
        return NO;
    int64_t N = 0;
    XTIROperand* nxo = cmp.operands[0];
    if (nxo.kind != XTIROperandKindUse || !ouConst(cmp.operands[1], defOf, &N, 0))
        return NO;
    XTIRInsn* add = defOf[@(nxo.valueId)];
    if (!add || add.opcode != XTIROpAdd || add.operands.count < 2)
        return NO;
    XTIRInsn* iv = nil;
    for (NSUInteger k = 0; k < 2; k++)
        {
        XTIROperand* a = add.operands[k];
        XTIROperand* o = add.operands[1 - k];
        int64_t one = 0;
        if (a.kind != XTIROperandKindUse || !ouConst(o, defOf, &one, 0) || one != 1)
            continue;
        XTIRInsn* d = defOf[@(a.valueId)];
        if (d && d.opcode == XTIROpPhi && [B.phiNodes indexOfObjectIdenticalTo:d] != NSNotFound)
            iv = d;
        }
    if (!iv)
        return NO;
    XTIROperand* back = ouIncoming(iv, Lt);
    int64_t S = 0;
    if (!back || back.kind != XTIROperandKindUse || back.valueId != nxo.valueId
        || !ouConst(ouIncoming(iv, L.pre), defOf, &S, 0))
        return NO;
    if (S < 0 || N <= S || N - S > 0x40000000LL)
        return NO;
    // Every value B's phis take on the back edge is a value, not an
    // immediate, so each copy's phi has something to stand for it.
    for (XTIRInsn* phi in B.phiNodes)
        {
        XTIROperand* o = ouIncoming(phi, Lt);
        if (!o || o.kind != XTIROperandKindUse)
            return NO;
        }
    int64_t T = N - S;
    NSUInteger K = T % 4 == 0 ? 4 : T % 3 == 0 ? 3 : T % 2 == 0 ? 2 : 0;
    if (K == 0 || T < (int64_t)K)
        return NO;
    [self applyIn:fn header:B latch:Lt exit:X inLoop:inL copies:K];
    return YES;
    }

- (void)applyIn:(XTIRFunction*)fn header:(XTIRBlock*)B latch:(XTIRBlock*)Lt exit:(XTIRBlock*)X
         inLoop:(NSSet<NSValue*>*)inL copies:(NSUInteger)K
    {
    // The loop's blocks in function order; the copies go after the last.
    NSMutableArray<XTIRBlock*>* blks = [NSMutableArray array];
    NSUInteger lastIdx = 0;
    for (NSUInteger i = 0; i < fn.blocks.count; i++)
        {
        XTIRBlock* bb = fn.blocks[i];
        if (![inL containsObject:OU_KEY(bb)])
            continue;
        [blks addObject:bb];
        lastIdx = i;
        }
    NSMutableArray<XTIRBlock*>* made = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, NSNumber*>* prev = nil;
    // Each copy's latch and entry; the latches are rewired only once every
    // copy is made, so each is cloned from the untouched original.
    NSMutableArray<XTIRBlock*>* latches = [NSMutableArray arrayWithObject:Lt];
    NSMutableArray<XTIRBlock*>* entries = [NSMutableArray arrayWithObject:B];
    for (NSUInteger j = 1; j < K; j++)
        {
        NSMutableDictionary<NSNumber*, NSNumber*>* vmap = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSValue*, XTIRBlock*>* bmap = [NSMutableDictionary dictionary];
        // Copy j's header phis are the values copy j-1 sent back.
        for (XTIRInsn* phi in B.phiNodes)
            {
            XTIRValueId v = ouIncoming(phi, Lt).valueId;
            NSNumber* m = prev[@(v)];
            vmap[@(phi.result.valueId)] = m ?: @(v);
            }
        for (XTIRBlock* bb in blks)
            {
            XTIRBlock* nb = [[XTIRBlock alloc] init];
            nb.name = ouUniqueBlockName(fn, [NSString stringWithFormat:@"%@_ou%lu", bb.name ?: @"bb", (unsigned long)j]);
            bmap[OU_KEY(bb)] = nb;
            }
        // Every result first: a phi, and an instruction in a block listed
        // before the one defining its operand, name values made later.
        for (XTIRBlock* bb in blks)
            {
            XTIRBlock* nb = bmap[OU_KEY(bb)];
            if (bb != B)
                for (XTIRInsn* phi in bb.phiNodes)
                    ouNewResult(fn, vmap, phi, nb, 0);
            NSUInteger idx = 0;
            for (XTIRInsn* n in bb.instructions)
                ouNewResult(fn, vmap, n, nb, idx++);
            if (bb.terminator)
                ouNewResult(fn, vmap, bb.terminator, nb, idx);
            }
        for (XTIRBlock* bb in blks)
            {
            XTIRBlock* nb = bmap[OU_KEY(bb)];
            if (bb != B)
                for (XTIRInsn* phi in bb.phiNodes)
                    [nb.phiNodes addObject:ouClone(fn, phi, vmap, bmap)];
            for (XTIRInsn* n in bb.instructions)
                [nb appendInstruction:ouClone(fn, n, vmap, bmap)];
            if (bb.terminator)
                [nb setTerminator:ouClone(fn, bb.terminator, vmap, bmap)];
            [made addObject:nb];
            }
        [latches addObject:bmap[OU_KEY(Lt)]];
        [entries addObject:bmap[OU_KEY(B)]];
        prev = vmap;
        }
    // Each copy but the last falls straight into the next: T is a multiple
    // of K, so its test would always go round.
    for (NSUInteger j = 0; j + 1 < K; j++)
        {
        XTIRBlock* lj = latches[j];
        XTIRInsn* br = [[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                 result:nil
                                               operands:@[ [XTIROperand blockWithRef:entries[j + 1]] ]
                                                 dbgLoc:lj.terminator.dbgLoc];
        [lj resetTerminator];
        [lj setTerminator:br];
        }
    XTIRBlock* prevLatch = latches[K - 1];
    // The last copy tests, and goes round to B or out to X.
    NSMutableArray<XTIROperand*>* lt = [prevLatch.terminator.operands mutableCopy];
    lt[1] = [XTIROperand blockWithRef:B];
    [prevLatch.terminator replaceOperands:lt];
    for (XTIRInsn* phi in B.phiNodes)
        {
        NSMutableArray<XTIROperand*>* ops = [phi.operands mutableCopy];
        for (NSUInteger k = 0; k + 1 < ops.count; k += 2)
            if (ops[k].blockRef == Lt)
                {
                ops[k] = [XTIROperand blockWithRef:prevLatch];
                ops[k + 1] = ouSubst(prev, nil, ops[k + 1]);
                }
        [phi replaceOperands:ops];
        }
    // After the loop, every value it made is the last copy's, and X's phis
    // come from the last copy's latch.
    for (XTIRBlock* bb in fn.blocks)
        {
        if ([inL containsObject:OU_KEY(bb)])
            continue;
        for (XTIRInsn* phi in bb.phiNodes)
            {
            NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:phi.operands.count];
            for (XTIROperand* o in phi.operands)
                {
                if (o.kind == XTIROperandKindBlock && o.blockRef == Lt)
                    [ops addObject:[XTIROperand blockWithRef:prevLatch]];
                else
                    [ops addObject:ouSubst(prev, nil, o)];
                }
            [phi replaceOperands:ops];
            }
        NSMutableArray<XTIRInsn*>* all = [bb.instructions mutableCopy];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* n in all)
            {
            NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:n.operands.count];
            for (XTIROperand* o in n.operands)
                [ops addObject:ouSubst(prev, nil, o)];
            [n replaceOperands:ops];
            }
        }
    [fn.blocks insertObjects:made
                   atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(lastIdx + 1, made.count)]];
    }

@end
