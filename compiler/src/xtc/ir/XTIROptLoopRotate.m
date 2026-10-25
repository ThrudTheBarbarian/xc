#import "XTIROptLoopRotate.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"

@interface XTLoopRotCand : NSObject
@property(nonatomic) XTIRBlock* H;       // header (becomes the peeled first test)
@property(nonatomic) XTIRBlock* B;       // the body's entry (becomes the loop header)
@property(nonatomic) XTIRBlock* L;       // the latch: the one body block that branches back to H
@property(nonatomic) NSSet<XTIRBlock*>* R; // the body: everything reachable from B without passing H
@property(nonatomic) XTIRBlock* E;       // exit
@property(nonatomic) XTIRValueId condId; // the guard result feeding H's CondBranch
@property(nonatomic) BOOL entryTrue;     // the guard holds on the entry values: no zero-trip path
@end
@implementation XTLoopRotCand
@end

// A loop whose test is a short-circuit chain, `while (a && b)`: H1 carries the
// phis and tests `a`, H2..Hk test the rest, and every one of them leaves to the
// same E.
@interface XTLoopRotChain : NSObject
@property(nonatomic) NSArray<XTIRBlock*>* chain; // H1..Hk
@property(nonatomic) XTIRBlock* B;
@property(nonatomic) XTIRBlock* L;
@property(nonatomic) NSSet<XTIRBlock*>* R;
@property(nonatomic) XTIRBlock* E;
@end
@implementation XTLoopRotChain
@end

@implementation XTIROptLoopRotate

- (NSString*)passName
    {
    return @"loop-rotate";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

// Header guard instructions must be safe to duplicate: pure value computation or
// a plain (speculatable) load — no store, call, or other side effect. The peeled
// copy reads exactly what the original header read on entry, so duplicating a
// load adds no new access.
static BOOL dupSafe(XTIRInsn* insn)
    {
    switch (insn.opcode)
        {
    case XTIROpConst:
    case XTIROpCopy:
    case XTIROpAdd:
    case XTIROpSub:
    case XTIROpMul:
    case XTIROpNeg:
    case XTIROpAnd:
    case XTIROpOr:
    case XTIROpXor:
    case XTIROpNot:
    case XTIROpShl:
    case XTIROpLShr:
    case XTIROpAShr:
    case XTIROpRol:
    case XTIROpRor:
    case XTIROpFAdd:
    case XTIROpFSub:
    case XTIROpFMul:
    case XTIROpFNeg:
    case XTIROpFSqrt:
    case XTIROpICmp:
    case XTIROpFCmp:
    case XTIROpSelect:
    case XTIROpSExt:
    case XTIROpZExt:
    case XTIROpTrunc:
    case XTIROpBitcast:
    case XTIROpIntToPtr:
    case XTIROpPtrToInt:
    case XTIROpFpToSI:
    case XTIROpFpToUI:
    case XTIROpSIToFp:
    case XTIROpUIToFp:
    case XTIROpFpExt:
    case XTIROpFpTrunc:
    case XTIROpAddrOf:
    case XTIROpFieldAddr:
    case XTIROpElementAddr:
    case XTIROpLoad: // pure, speculatable (same address the header read)
        return YES;
    default:
        return NO;
        }
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (!prof.rotatesLoops)
        return YES;
    if (getenv("XTROT_OFF"))
        return YES; // A/B measurement escape hatch
    for (XTIRFunction* fn in mod.functions)
        [self runOnFunction:fn];
    return YES;
    }

// A small non-negative constant an operand is known to hold: an immediate, a
// Const, or an extension or truncation of one. Kept to [0, 2^31) and to what
// the type holds as a positive value, so signed and unsigned compares agree.
static BOOL rotConst(XTIROperand* o, NSDictionary<NSNumber*, XTIRInsn*>* defs, int depth, int64_t* out)
    {
    if (depth > 4 || !o)
        return NO;
    int64_t v;
    XTIRType* t = nil;
    if (o.kind == XTIROperandKindImmI)
        {
        v = o.intValue;
        t = o.type;
        }
    else if (o.kind == XTIROperandKindUse)
        {
        XTIRInsn* d = defs[@(o.valueId)];
        if (!d || d.operands.count < 1)
            return NO;
        if (d.opcode == XTIROpConst)
            {
            if (d.operands[0].kind != XTIROperandKindImmI)
                return NO;
            v = d.operands[0].intValue;
            }
        else if (d.opcode == XTIROpZExt || d.opcode == XTIROpSExt || d.opcode == XTIROpTrunc)
            {
            if (!rotConst(d.operands[0], defs, depth + 1, &v))
                return NO;
            }
        else
            return NO;
        t = d.result.type;
        }
    else
        return NO;
    if (v < 0 || v >= ((int64_t)1 << 31))
        return NO;
    uint32_t bw = t ? t.byteWidth : 0;
    if (bw >= 1 && bw < 4 && v >= ((int64_t)1 << (8 * bw - 1)))
        return NO;
    *out = v;
    return YES;
    }

static NSArray<XTIRBlock*>* predsOf(XTIRBlock* target, XTIRFunction* fn)
    {
    NSMutableArray<XTIRBlock*>* p = [NSMutableArray array];
    for (XTIRBlock* b in fn.blocks)
        {
        XTIRInsn* t = b.terminator;
        if (!t)
            continue;
        for (XTIROperand* o in t.operands)
            if (o.kind == XTIROperandKindBlock && o.blockRef == target)
                {
                [p addObject:b];
                break;
                }
        }
    return p;
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    // One loop at a time, re-recognising from the live CFG. A rotated loop's
    // back-edge is conditional (B→B via CondBranch), so it no longer matches the
    // top-tested pattern — the bound is just a backstop.
    for (NSUInteger iter = 0; iter < 512; iter++)
        {
        XTLoopRotCand* c = [self recognise:fn];
        if (c)
            {
            [self apply:c inFunction:fn];
            continue;
            }
        XTLoopRotChain* cc = self.profile.rotatesChainLoops ? [self recogniseChain:fn] : nil;
        if (!cc)
            break;
        [self applyChain:cc inFunction:fn];
        }
    }

// Every instruction of every block, terminator included.
static NSArray<XTIRInsn*>* allInsns(XTIRBlock* bb)
    {
    NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
    [all addObjectsFromArray:bb.phiNodes];
    [all addObjectsFromArray:bb.instructions];
    if (bb.terminator)
        [all addObject:bb.terminator];
    return all;
    }

// The chain block a CondBranch continues to: the target that is not E.
static XTIRBlock* chainNext(XTIRBlock* h, XTIRBlock* E)
    {
    XTIRInsn* t = h.terminator;
    XTIRBlock *t0 = t.operands[1].blockRef, *t1 = t.operands[2].blockRef;
    return t0 == E ? t1 : t0;
    }

// A block that tests a condition it computes itself and branches on it.
static BOOL chainTest(XTIRBlock* h)
    {
    XTIRInsn* t = h.terminator;
    if (!t || t.opcode != XTIROpCondBranch || t.operands.count < 3 || t.operands[0].kind != XTIROperandKindUse)
        return NO;
    XTIRBlock *t0 = t.operands[1].blockRef, *t1 = t.operands[2].blockRef;
    if (!t0 || !t1 || t0 == t1)
        return NO;
    for (XTIRInsn* i in h.instructions)
        if (i.result && i.result.valueId == t.operands[0].valueId)
            return YES;
    return NO;
    }

// A top-tested loop whose test is a chain of two or more blocks, as
// `while (j > 0 && a[j-1] > v)` lowers:
//
//     H1:  phi …; <guard 1>; CondBranch c1, H2, E
//     H2:  <guard 2>;        CondBranch c2, B, E        (… up to Hk)
//     B…L: <body>; Branch H1
//
// Unlike the one-block case, the body may read what the guard computed (the
// loaded `a[j-1]`, and `j-1` as the next `j`): rotation threads those values
// into B.
- (nullable XTLoopRotChain*)recogniseChain:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result)
                defBlk[@(p.result.valueId)] = bb;
        for (XTIRInsn* i in bb.instructions)
            {
            if (i.result)
                defBlk[@(i.result.valueId)] = bb;
            if (i.memoryResult)
                defBlk[@(i.memoryResult.valueId)] = bb;
            }
        }
    for (XTIRBlock* H1 in fn.blocks)
        {
        if (H1.phiNodes.count == 0 || !chainTest(H1))
            continue;
        BOOL ok = YES;
        for (XTIRInsn* p in H1.phiNodes)
            if (!p.result || p.memoryResult || p.operands.count != 4 || p.result.type.kind == XTIRTypeKindVec)
                ok = NO;
        if (!ok)
            continue;
        // E is the target H1 shares with the block it continues to.
        XTIRBlock* E = nil;
        for (NSUInteger side = 1; side <= 2 && !E; side++)
            {
            XTIRBlock* n = H1.terminator.operands[side].blockRef;
            XTIRBlock* e = H1.terminator.operands[3 - side].blockRef;
            if (n == H1 || e == H1 || n.phiNodes.count || !chainTest(n))
                continue;
            if (n.terminator.operands[1].blockRef == e || n.terminator.operands[2].blockRef == e)
                E = e;
            }
        if (!E || E.phiNodes.count)
            continue;
        NSMutableArray<XTIRBlock*>* chain = [NSMutableArray arrayWithObject:H1];
        XTIRBlock* x = chainNext(H1, E);
        while (chain.count < 4 && x != H1 && x != E && x.phiNodes.count == 0 && chainTest(x) &&
               (x.terminator.operands[1].blockRef == E || x.terminator.operands[2].blockRef == E))
            {
            NSArray<XTIRBlock*>* xp = predsOf(x, fn);
            if (xp.count != 1 || xp[0] != chain.lastObject)
                break;
            [chain addObject:x];
            x = chainNext(x, E);
            }
        XTIRBlock* B = x;
        if (chain.count < 2 || B == H1 || B == E || B.phiNodes.count || [chain containsObject:B])
            continue;
        if (predsOf(B, fn).count != 1)
            continue;
        // The body region, as the one-block case finds it.
        NSMutableSet<XTIRBlock*>* R = [NSMutableSet setWithObject:B];
        NSMutableArray<XTIRBlock*>* work = [NSMutableArray arrayWithObject:B];
        XTIRBlock* L = nil;
        while (work.count && ok)
            {
            XTIRBlock* w = work.lastObject;
            [work removeLastObject];
            XTIRInsn* wt = w.terminator;
            if (!wt)
                {
                ok = NO;
                break;
                }
            for (XTIROperand* o in wt.operands)
                {
                if (o.kind != XTIROperandKindBlock || !o.blockRef)
                    continue;
                XTIRBlock* s = o.blockRef;
                if (s == H1)
                    {
                    if (L || wt.opcode != XTIROpBranch)
                        ok = NO;
                    L = w;
                    continue;
                    }
                if (s == E || [chain containsObject:s])
                    {
                    ok = NO;
                    break;
                    }
                if (![R containsObject:s])
                    {
                    [R addObject:s];
                    [work addObject:s];
                    }
                }
            }
        if (!ok || !L)
            continue;
        for (XTIRBlock* r in R)
            for (XTIRBlock* pb in predsOf(r, fn))
                if (![R containsObject:pb] && !(r == B && pb == chain.lastObject))
                    ok = NO;
        NSArray<XTIRBlock*>* hp = predsOf(H1, fn);
        if (!ok || hp.count != 2 || ![hp containsObject:L])
            continue;
        // E is reached from the chain alone.
        NSArray<XTIRBlock*>* ep = predsOf(E, fn);
        if (ep.count != chain.count)
            continue;
        for (XTIRBlock* p in ep)
            if (![chain containsObject:p])
                ok = NO;
        // Every guard instruction can be duplicated and reads nothing the body
        // computes; a value it defines is read only in the chain, the body or
        // (H1's phis alone) after the loop.
        NSMutableSet<NSNumber*>* chainVals = [NSMutableSet set];
        for (XTIRBlock* h in chain)
            for (XTIRInsn* i in h.instructions)
                {
                if (!dupSafe(i))
                    ok = NO;
                for (XTIROperand* o in i.operands)
                    if (o.kind == XTIROperandKindUse && [R containsObject:defBlk[@(o.valueId)]])
                        ok = NO;
                if (i.result)
                    [chainVals addObject:@(i.result.valueId)];
                }
        if (!ok)
            continue;
        for (XTIRBlock* bb in fn.blocks)
            {
            if ([chain containsObject:bb] || [R containsObject:bb])
                continue;
            for (XTIRInsn* u in allInsns(bb))
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && [chainVals containsObject:@(o.valueId)])
                        ok = NO;
            }
        if (!ok)
            continue;
        XTLoopRotChain* c = [XTLoopRotChain new];
        c.chain = chain;
        c.B = B;
        c.L = L;
        c.R = R;
        c.E = E;
        return c;
        }
    return nil;
    }

// Rotation of a chain loop:
//
//     H1..Hk: the peeled first test, on the preheader's values
//     B:      phi …; <values of the chain the body reads>; <body>
//     L:      <guard 1 on the next values>; CondBranch c1', L2', E
//     L2'…:   <guard 2 …>;                  CondBranch c2', B, E
//     E:      phi merging every exit edge, for each carried value read after
//
// A chain value the body reads is RECOMPUTED at the top of B when it is
// arithmetic (`j-1` from B's own `j`), which costs one instruction and no
// carried register; a load is carried in by a phi of B instead.
- (void)applyChain:(XTLoopRotChain*)c inFunction:(XTIRFunction*)fn
    {
    NSArray<XTIRBlock*>* chain = c.chain;
    XTIRBlock *H1 = chain[0], *B = c.B, *L = c.L, *E = c.E;
    NSSet<XTIRBlock*>* R = c.R;
    XTIRBlock* Hk = chain.lastObject;
    XTIRType* memTy = [XTIRType memoryType];

    // 1. Each H1 phi's (preheader init, back-edge next), and a new B phi value.
    NSArray<XTIRInsn*>* phis = [H1.phiNodes copy];
    NSMutableArray<XTIROperand*>* initOp = [NSMutableArray array];
    NSMutableArray<XTIROperand*>* nextOp = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, XTIROperand*>* bMap = [NSMutableDictionary dictionary]; // value → its B version
    NSMutableArray<XTIRValue*>* pbVals = [NSMutableArray array];
    for (XTIRInsn* phi in phis)
        {
        XTIROperand *fromPH = nil, *fromL = nil;
        for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
            {
            if (phi.operands[k].blockRef == L)
                fromL = phi.operands[k + 1];
            else
                fromPH = phi.operands[k + 1];
            }
        [initOp addObject:fromPH];
        [nextOp addObject:fromL];
        XTIRValue* v = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                     type:phi.result.type
                                                  defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:0]];
        [fn registerValue:v];
        [pbVals addObject:v];
        bMap[@(phi.result.valueId)] = [XTIROperand useWithValueId:v.valueId];
        }

    // 2. The chain values B needs: those the body or a back-edge value reads,
    //    and, for one that is recomputed, its own operands.
    NSMutableArray<XTIRInsn*>* chainInsns = [NSMutableArray array];
    for (XTIRBlock* h in chain)
        [chainInsns addObjectsFromArray:h.instructions];
    NSMutableSet<NSNumber*>* chainVals = [NSMutableSet set];
    for (XTIRInsn* i in chainInsns)
        if (i.result)
            [chainVals addObject:@(i.result.valueId)];
    //    What the body reads is needed at the top of B; what only the back
    //    edge reads is recomputed at the end of L, after the body's last read
    //    of the value it replaces, so the two can share a register.
    NSMutableSet<NSNumber*>* needR = [NSMutableSet set];
    for (XTIRBlock* rb in fn.blocks)
        if ([R containsObject:rb])
            for (XTIRInsn* u in allInsns(rb))
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && [chainVals containsObject:@(o.valueId)])
                        [needR addObject:@(o.valueId)];
    NSMutableSet<NSNumber*>* need = [NSMutableSet set];
    for (XTIROperand* o in nextOp)
        if (o.kind == XTIROperandKindUse && [chainVals containsObject:@(o.valueId)])
            [need addObject:@(o.valueId)];
    for (NSMutableSet<NSNumber*>* set in @[ needR, need ])
        for (NSInteger q = (NSInteger)chainInsns.count - 1; q >= 0; q--)
            {
            XTIRInsn* i = chainInsns[(NSUInteger)q];
            if (!i.result || ![set containsObject:@(i.result.valueId)] || i.opcode == XTIROpLoad)
                continue;
            for (XTIROperand* o in i.operands)
                if (o.kind == XTIROperandKindUse && [chainVals containsObject:@(o.valueId)])
                    [set addObject:@(o.valueId)];
            }
    [need unionSet:needR];

    // 3. Their B versions, in chain order: a recomputation (at the top of B, or the end of L), or
    //    (a load) a phi whose incomings are filled once the clones exist.
    NSMutableArray<XTIRInsn*>* remat = [NSMutableArray array];
    NSMutableArray<XTIRInsn*>* lateRemat = [NSMutableArray array];
    NSMutableArray<XTIRInsn*>* loadPhis = [NSMutableArray array];
    NSMutableArray<XTIRInsn*>* loadOrig = [NSMutableArray array];
    for (XTIRInsn* i in chainInsns)
        {
        if (!i.result || ![need containsObject:@(i.result.valueId)])
            continue;
        XTIRValue* v = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                     type:i.result.type
                                                  defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:0]];
        [fn registerValue:v];
        if (i.opcode == XTIROpLoad)
            {
            XTIRInsn* p = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi result:v operands:@[] dbgLoc:i.dbgLoc];
            [loadPhis addObject:p];
            [loadOrig addObject:i];
            }
        else
            {
            NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
            for (XTIROperand* o in i.operands)
                [ops addObject:(o.kind == XTIROperandKindUse && bMap[@(o.valueId)]) ? bMap[@(o.valueId)] : o];
            XTIRInsn* r = (XTIROpCarriesPredicate(i.opcode))
                              ? [[XTIRInsn alloc] initWithOpcode:i.opcode result:v operands:ops predicate:i.predicate dbgLoc:i.dbgLoc]
                              : [[XTIRInsn alloc] initWithOpcode:i.opcode result:v operands:ops dbgLoc:i.dbgLoc];
            [([needR containsObject:@(i.result.valueId)] ? remat : lateRemat) addObject:r];
            }
        bMap[@(i.result.valueId)] = [XTIROperand useWithValueId:v.valueId];
        }

    // `next` as B sees it.
    NSMutableArray<XTIROperand*>* nextB = [NSMutableArray array];
    for (XTIROperand* o in nextOp)
        [nextB addObject:(o.kind == XTIROperandKindUse && bMap[@(o.valueId)]) ? bMap[@(o.valueId)] : o];

    // 4. The body reads the B versions.
    for (XTIRBlock* rb in fn.blocks)
        {
        if (![R containsObject:rb])
            continue;
        for (XTIRInsn* u in allInsns(rb))
            {
            BOOL ch = NO;
            NSMutableArray<XTIROperand*>* ops = [u.operands mutableCopy];
            for (NSUInteger k = 0; k < ops.count; k++)
                if (ops[k].kind == XTIROperandKindUse && bMap[@(ops[k].valueId)])
                    {
                    ops[k] = bMap[@(ops[k].valueId)];
                    ch = YES;
                    }
            if (ch)
                [u replaceOperands:ops];
            }
        }

    // 5. Clone the chain to the bottom of the body: H1's copy into L, each
    //    later block's into a new block after it. Phi values read their next
    //    values; chain values read their clones.
    [L.instructions addObjectsFromArray:lateRemat];
    NSMutableDictionary<NSNumber*, XTIROperand*>* gMap = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < phis.count; i++)
        gMap[@(phis[i].result.valueId)] = nextB[i];
    NSMutableArray<XTIRBlock*>* clones = [NSMutableArray arrayWithObject:L];
    for (NSUInteger h = 1; h < chain.count; h++)
        {
        XTIRBlock* nb = [[XTIRBlock alloc] init];
        nb.name = [NSString stringWithFormat:@"%@_rot", chain[h].name ?: @"test"];
        [clones addObject:nb];
        }
    for (NSUInteger h = 0; h < chain.count; h++)
        {
        XTIRBlock* dst = clones[h];
        for (XTIRInsn* insn in chain[h].instructions)
            {
            NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
            for (XTIROperand* o in insn.operands)
                [ops addObject:(o.kind == XTIROperandKindUse && gMap[@(o.valueId)]) ? gMap[@(o.valueId)] : o];
            XTIRValue *nr = nil, *nm = nil;
            if (insn.result)
                {
                nr = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                   type:insn.result.type
                                                defSite:[[XTIRDefSite alloc] initWithBlock:dst insnIndex:dst.instructions.count]];
                [fn registerValue:nr];
                gMap[@(insn.result.valueId)] = [XTIROperand useWithValueId:nr.valueId];
                }
            if (insn.memoryResult)
                {
                nm = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                   type:memTy
                                                defSite:[[XTIRDefSite alloc] initWithBlock:dst insnIndex:dst.instructions.count]];
                [fn registerValue:nm];
                }
            XTIRInsn* cl = (XTIROpCarriesPredicate(insn.opcode))
                               ? [[XTIRInsn alloc] initWithOpcode:insn.opcode result:nr operands:ops predicate:insn.predicate dbgLoc:insn.dbgLoc]
                               : [[XTIRInsn alloc] initWithOpcode:insn.opcode result:nr operands:ops dbgLoc:insn.dbgLoc];
            cl.memoryResult = nm;
            [dst.instructions addObject:cl];
            }
        XTIRInsn* ht = chain[h].terminator;
        NSMutableArray<XTIROperand*>* tops = [NSMutableArray arrayWithObject:gMap[@(ht.operands[0].valueId)]];
        for (NSUInteger k = 1; k < 3; k++)
            {
            XTIRBlock* t = ht.operands[k].blockRef;
            [tops addObject:(h + 1 < chain.count && t == chain[h + 1]) ? [XTIROperand blockWithRef:clones[h + 1]]
                                                                      : ht.operands[k]];
            }
        [dst resetTerminator];
        [dst setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpCondBranch
                                                     result:nil
                                                   operands:tops
                                                  predicate:ht.predicate
                                                     dbgLoc:ht.dbgLoc]];
        }
    NSUInteger at = [fn.blocks indexOfObject:L] + 1;
    [fn.blocks insertObjects:[clones subarrayWithRange:NSMakeRange(1, clones.count - 1)]
                   atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(at, clones.count - 1)]];
    XTIRBlock* Lk = clones.lastObject;

    // 6. B's phis and recomputations.
    NSMutableArray<XTIRInsn*>* bPhis = [NSMutableArray array];
    for (NSUInteger i = 0; i < phis.count; i++)
        [bPhis addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                   result:pbVals[i]
                                                 operands:@[ [XTIROperand blockWithRef:Hk], initOp[i],
                                                             [XTIROperand blockWithRef:Lk], nextB[i] ]
                                                   dbgLoc:phis[i].dbgLoc]];
    for (NSUInteger i = 0; i < loadPhis.count; i++)
        {
        XTIRValueId ov = loadOrig[i].result.valueId;
        [loadPhis[i] replaceOperands:@[ [XTIROperand blockWithRef:Hk], [XTIROperand useWithValueId:ov],
                                        [XTIROperand blockWithRef:Lk], gMap[@(ov)] ]];
        [bPhis addObject:loadPhis[i]];
        }
    [B.phiNodes insertObjects:bPhis atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, bPhis.count)]];
    [B.instructions insertObjects:remat atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, remat.count)]];

    // 7. The chain itself is the peeled test: phi values become the inits.
    NSMutableDictionary<NSNumber*, XTIROperand*>* hReplace = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < phis.count; i++)
        hReplace[@(phis[i].result.valueId)] = initOp[i];
    for (XTIRBlock* h in chain)
        for (XTIRInsn* u in h.instructions)
            {
            BOOL ch = NO;
            NSMutableArray<XTIROperand*>* ops = [u.operands mutableCopy];
            for (NSUInteger k = 0; k < ops.count; k++)
                if (ops[k].kind == XTIROperandKindUse && hReplace[@(ops[k].valueId)])
                    {
                    ops[k] = hReplace[@(ops[k].valueId)];
                    ch = YES;
                    }
            if (ch)
                [u replaceOperands:ops];
            }
    [H1.phiNodes removeAllObjects];

    // 8. Exit phis for the carried values read after the loop, merging every
    //    edge into E: the peeled tests carry the init, the clones the next.
    NSMutableArray<XTIRInsn*>* exitPhis = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, NSNumber*>* exitMap = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < phis.count; i++)
        {
        XTIRValueId pid = phis[i].result.valueId;
        BOOL esc = NO;
        for (XTIRBlock* bb in fn.blocks)
            {
            if ([chain containsObject:bb] || [R containsObject:bb] || [clones containsObject:bb])
                continue;
            for (XTIRInsn* u in allInsns(bb))
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == pid)
                        esc = YES;
            }
        if (!esc)
            continue;
        XTIRValue* v = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                     type:phis[i].result.type
                                                  defSite:[[XTIRDefSite alloc] initWithBlock:E insnIndex:0]];
        [fn registerValue:v];
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        for (XTIRBlock* h in chain)
            {
            [ops addObject:[XTIROperand blockWithRef:h]];
            [ops addObject:initOp[i]];
            }
        for (XTIRBlock* h in clones)
            {
            [ops addObject:[XTIROperand blockWithRef:h]];
            [ops addObject:nextB[i]];
            }
        XTIRInsn* ep = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi result:v operands:ops dbgLoc:nil];
        [exitPhis addObject:ep];
        exitMap[@(pid)] = @(v.valueId);
        }
    [E.phiNodes insertObjects:exitPhis atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, exitPhis.count)]];
    if (!exitMap.count)
        return;
    for (XTIRBlock* bb in fn.blocks)
        {
        if ([chain containsObject:bb] || [R containsObject:bb] || [clones containsObject:bb])
            continue;
        for (XTIRInsn* u in allInsns(bb))
            {
            if ([exitPhis containsObject:u])
                continue;
            BOOL ch = NO;
            NSMutableArray<XTIROperand*>* ops = [u.operands mutableCopy];
            for (NSUInteger k = 0; k < ops.count; k++)
                if (ops[k].kind == XTIROperandKindUse && exitMap[@(ops[k].valueId)])
                    {
                    ops[k] = [XTIROperand useWithValueId:(XTIRValueId)exitMap[@(ops[k].valueId)].unsignedLongLongValue];
                    ch = YES;
                    }
            if (ch)
                [u replaceOperands:ops];
            }
        }
    }

- (nullable XTLoopRotCand*)recognise:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            {
            if (p.result)
                defBlk[@(p.result.valueId)] = bb;
            }
        for (XTIRInsn* i in bb.instructions)
            {
            if (i.result)
                defBlk[@(i.result.valueId)] = bb;
            if (i.memoryResult)
                defBlk[@(i.memoryResult.valueId)] = bb;
            }
        }

    for (XTIRBlock* H in fn.blocks)
        {
        if (H.phiNodes.count == 0)
            continue;
        // A header carrying a vector (reduction-accumulator) phi is an
        // already-vectorised loop; rotating it would duplicate the vector phi,
        // which the backend's in-place-accumulate coalescing can't represent.
        BOOL hasVecPhi = NO;
        for (XTIRInsn* p in H.phiNodes)
            if (p.result && p.result.type.kind == XTIRTypeKindVec)
                {
                hasVecPhi = YES;
                break;
                }
        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRValueId condId = term.operands[0].valueId;
        if (defBlk[@(condId)] != H)
            continue; // guard must be computed in H
        // …by an INSTRUCTION. A condition that is itself one of H's phis
        // (`while (again)`) has no guard to clone: the rewrite removes the
        // phi and left both branches testing a value that no longer existed.
        BOOL condIsPhi = NO;
        for (XTIRInsn* p in H.phiNodes)
            if (p.result && p.result.valueId == condId)
                condIsPhi = YES;
        if (condIsPhi)
            continue;

        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        if (!t0 || !t1 || t0 == t1)
            continue;
        // The body is a REGION, not only a single block: B, the successor of H
        // that starts it, and everything reachable from B without passing
        // through H. It must be left only by going back to H, and exactly one
        // of its blocks — the latch L — does that, with a plain branch. A
        // one-block body is the case L == B.
        XTIRBlock *B = nil, *E = nil, *L = nil;
        NSMutableSet<XTIRBlock*>* R = nil;
        for (NSUInteger side = 0; side < 2 && !B; side++)
            {
            XTIRBlock* b = side == 0 ? t0 : t1;
            XTIRBlock* e = side == 0 ? t1 : t0;
            if (b == H || b.phiNodes.count != 0)
                continue;
            NSMutableSet<XTIRBlock*>* reg = [NSMutableSet setWithObject:b];
            NSMutableArray<XTIRBlock*>* work = [NSMutableArray arrayWithObject:b];
            BOOL okR = YES;
            XTIRBlock* latchBlk = nil;
            while (work.count && okR)
                {
                XTIRBlock* x = work.lastObject;
                [work removeLastObject];
                XTIRInsn* xt = x.terminator;
                if (!xt)
                    {
                    okR = NO;
                    break;
                    }
                for (XTIROperand* o in xt.operands)
                    {
                    if (o.kind != XTIROperandKindBlock || !o.blockRef)
                        continue;
                    XTIRBlock* s = o.blockRef;
                    if (s == H)
                        {
                        // The one way back, and an unconditional one.
                        if (latchBlk || xt.opcode != XTIROpBranch)
                            okR = NO;
                        latchBlk = x;
                        continue;
                        }
                    if (s == e)
                        {
                        okR = NO; // a second exit
                        break;
                        }
                    if (![reg containsObject:s])
                        {
                        [reg addObject:s];
                        [work addObject:s];
                        }
                    }
                }
            if (!okR || !latchBlk || [reg containsObject:e])
                continue;
            // Nothing outside the region may enter it except through B.
            BOOL closed = YES;
            for (XTIRBlock* x in reg)
                for (XTIRBlock* pb in predsOf(x, fn))
                    if (![reg containsObject:pb] && !(x == b && pb == H))
                        closed = NO;
            if (!closed)
                continue;
            // A multi-block body with no branching of its own — the chain of
            // blocks an unrolled body is split into — is left as it was: the
            // one-block rule never rotated it, and rotating it measured slower
            // (mem_copy on the x86-64 host, 1.08 s -> 1.41 s) with no branch
            // saved. Rotation pays where the body branches (an `if`, an inner
            // loop): there it removes the trip through the header.
            if (reg.count > 1)
                {
                BOOL branches = NO;
                for (XTIRBlock* x in reg)
                    if (x.terminator.opcode != XTIROpBranch)
                        branches = YES;
                if (!branches)
                    continue;
                }
            B = b;
            E = e;
            L = latchBlk;
            R = reg;
            }
        if (!B || B == E || !E)
            continue;

        // B's only predecessor is H; H's predecessors are exactly {PH, L}.
        if (predsOf(B, fn).count != 1)
            continue;
        NSArray<XTIRBlock*>* hp = predsOf(H, fn);
        if (hp.count != 2 || ![hp containsObject:L])
            continue;

        // Every header non-phi instruction is the guard: safe to duplicate, with
        // its result used ONLY within H (so the body doesn't depend on a value
        // the rotation would have to thread), and referencing no B-defined value
        // (the peeled copy must be computable from preheader/loop-invariant data).
        BOOL ok = YES;
        for (XTIRInsn* insn in H.instructions)
            {
            if (!dupSafe(insn))
                {
                ok = NO;
                break;
                }
            for (XTIROperand* o in insn.operands)
                if (o.kind == XTIROperandKindUse && defBlk[@(o.valueId)] && [R containsObject:defBlk[@(o.valueId)]])
                    {
                    ok = NO;
                    break;
                    }
            if (!ok)
                break;
            // result/memResult used only in H
            for (XTIRBlock* bb in fn.blocks)
                {
                if (bb == H)
                    continue;
                NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
                [all addObjectsFromArray:bb.phiNodes];
                [all addObjectsFromArray:bb.instructions];
                if (bb.terminator)
                    [all addObject:bb.terminator];
                for (XTIRInsn* u in all)
                    for (XTIROperand* o in u.operands)
                        if (o.kind == XTIROperandKindUse && insn.result &&
                            o.valueId == insn.result.valueId)
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

        // Each header phi is a clean 2-way (PH, B) merge.
        for (XTIRInsn* phi in H.phiNodes)
            {
            if (!phi.result || phi.memoryResult || phi.operands.count != 4)
                {
                ok = NO;
                break;
                }
            }
        if (!ok)
            continue;

        // A header phi whose BACK-EDGE value is computed by a header guard is a
        // loop-carried recurrence the rotation cannot thread: the guard (e.g. the
        // `n - 1` of `while (n-- > 0)`) is duplicated, but the phi still reads the
        // original H-defined value, so the variable never advances and the loop
        // runs forever (bug 02). The condition modifies the induction variable, so
        // the "guard result used only in H" test above passes — the phi's own
        // back-edge use is in H — yet rotation is still unsound. Bail.
        for (XTIRInsn* phi in H.phiNodes)
            {
            for (NSUInteger i = 0; i + 1 < phi.operands.count; i += 2)
                {
                if (phi.operands[i].kind == XTIROperandKindBlock &&
                    phi.operands[i].blockRef == L &&
                    phi.operands[i + 1].kind == XTIROperandKindUse &&
                    defBlk[@(phi.operands[i + 1].valueId)] == H)
                    {
                    ok = NO;
                    break;
                    }
                }
            if (!ok)
                break;
            }
        if (!ok)
            continue;

        // Whether any carried value escapes (used outside H/B); if so an exit phi
        // is materialised in E and E must be reached only from H pre-rotation.
        BOOL anyEscape = NO;
        for (XTIRInsn* phi in H.phiNodes)
            {
            XTIRValueId pid = phi.result.valueId;
            BOOL esc = NO;
            for (XTIRBlock* bb in fn.blocks)
                {
                if (bb == H || [R containsObject:bb])
                    continue;
                NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
                [all addObjectsFromArray:bb.phiNodes];
                [all addObjectsFromArray:bb.instructions];
                if (bb.terminator)
                    [all addObject:bb.terminator];
                for (XTIRInsn* u in all)
                    for (XTIROperand* o in u.operands)
                        if (o.kind == XTIROperandKindUse && o.valueId == pid)
                            {
                            esc = YES;
                            break;
                            }
                if (esc)
                    break;
                }
            if (esc)
                {
                anyEscape = YES;
                break;
                }
            }
        if (anyEscape)
            {
            if (E.phiNodes.count != 0)
                continue; // we add exit phis here
            NSArray<XTIRBlock*>* ep = predsOf(E, fn);
            if (ep.count != 1 || ep[0] != H)
                continue; // exit phi covers H + B only
            }

        // Whether the guard holds on the entry values, so the loop runs at least
        // once: `for (k = 0; k < 32; k++)`. Then the rotated loop needs no
        // zero-trip path, so no exit phi, and a vector (accumulator) phi is not
        // duplicated, which is what kept vectorised loops from rotating, with a
        // copy per carried value at the bottom of every iteration.
        BOOL entryTrue = NO;
        XTIRInsn* condInsn = nil;
        for (XTIRInsn* insn in H.instructions)
            if (insn.result && insn.result.valueId == condId)
                condInsn = insn;
        if (condInsn && condInsn.opcode == XTIROpICmp && condInsn.operands.count == 2 && E.phiNodes.count == 0)
            {
            NSArray<XTIRBlock*>* ep = predsOf(E, fn);
            NSMutableDictionary<NSNumber*, XTIRInsn*>* defs = [NSMutableDictionary dictionary];
            for (XTIRBlock* bb in fn.blocks)
                for (XTIRInsn* i in bb.instructions)
                    if (i.result)
                        defs[@(i.result.valueId)] = i;
            int64_t vals[2];
            BOOL known = ep.count == 1 && ep[0] == H;
            for (NSUInteger k = 0; k < 2 && known; k++)
                {
                XTIROperand* o = condInsn.operands[k];
                // A header phi stands for its entry value.
                if (o.kind == XTIROperandKindUse)
                    for (XTIRInsn* phi in H.phiNodes)
                        if (phi.result.valueId == o.valueId)
                            for (NSUInteger q = 0; q + 1 < phi.operands.count; q += 2)
                                if (phi.operands[q].blockRef != L)
                                    o = phi.operands[q + 1];
                known = rotConst(o, defs, 0, &vals[k]);
                }
            if (known)
                {
                int64_t a = vals[0], b = vals[1];
                switch ((XTIRICmpPredicate)condInsn.predicate)
                    {
                    case XTIRICmpEQ: entryTrue = a == b; break;
                    case XTIRICmpNE: entryTrue = a != b; break;
                    case XTIRICmpSLT: case XTIRICmpULT: entryTrue = a < b; break;
                    case XTIRICmpSGT: case XTIRICmpUGT: entryTrue = a > b; break;
                    case XTIRICmpSLE: case XTIRICmpULE: entryTrue = a <= b; break;
                    case XTIRICmpSGE: case XTIRICmpUGE: entryTrue = a >= b; break;
                    default: break;
                    }
                // The branch must go to the body when the guard holds.
                if (term.operands[1].blockRef != B)
                    entryTrue = NO;
                }
            // Every escaping value must be a value the latch computes.
            for (XTIRInsn* phi in H.phiNodes)
                for (NSUInteger q = 0; q + 1 < phi.operands.count; q += 2)
                    if (phi.operands[q].blockRef == L && phi.operands[q + 1].kind != XTIROperandKindUse)
                        entryTrue = NO;
            }
        if (hasVecPhi && !entryTrue)
            continue;

        XTLoopRotCand* c = [XTLoopRotCand new];
        c.entryTrue = entryTrue;
        c.H = H;
        c.B = B;
        c.L = L;
        c.R = R;
        c.E = E;
        c.condId = condId;
        return c;
        }
    return nil;
    }

- (void)apply:(XTLoopRotCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock *H = c.H, *B = c.B, *E = c.E, *L = c.L;
    NSSet<XTIRBlock*>* R = c.R;
    XTIRType* memTy = [XTIRType memoryType];

    // 1. Capture each phi's (PH-incoming init, B-incoming next) operands.
    NSArray<XTIRInsn*>* phis = [H.phiNodes copy];
    NSMutableArray<XTIROperand*>* initOp = [NSMutableArray array];
    NSMutableArray<XTIROperand*>* nextOp = [NSMutableArray array];
    NSMutableArray<NSNumber*>* phiIds = [NSMutableArray array];
    for (XTIRInsn* phi in phis)
        {
        XTIROperand *fromPH = nil, *fromB = nil;
        for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
            {
            if (phi.operands[k].blockRef == L)
                fromB = phi.operands[k + 1];
            else
                fromPH = phi.operands[k + 1];
            }
        [initOp addObject:fromPH];
        [nextOp addObject:fromB];
        [phiIds addObject:@(phi.result.valueId)];
        }

    // 2. New B-resident phis: P_B = phi[(H, init), (B, next)]. The values are
    //    allocated FIRST, because `next` may itself be one of H's phis — a
    //    tail-recursion parameter the loop does not change is lowered as
    //    `%p = Phi [(entry, arg), (latch, %p)]` — and step 7 removes H's phis,
    //    so such a `next` has to name the NEW phi or the operand is left
    //    dangling. Same reason step 8 remaps its B-incoming.
    NSMutableArray<XTIRValue*>* pbVals = [NSMutableArray array];
    NSMutableArray<XTIRInsn*>* pbPhis = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, NSNumber*>* selfMap = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < phis.count; i++)
        {
        XTIRValueId rid = [fn allocateValueId];
        XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                     type:phis[i].result.type
                                                  defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:i]];
        [fn registerValue:v];
        [pbVals addObject:v];
        selfMap[phiIds[i]] = @(rid);
        }
    // `next` in terms of the new phis (identity unless it named an old one).
    NSMutableArray<XTIROperand*>* nextMapped = [NSMutableArray array];
    for (NSUInteger i = 0; i < phis.count; i++)
        {
        XTIROperand* nx = nextOp[i];
        NSNumber* rm = (nx.kind == XTIROperandKindUse) ? selfMap[@(nx.valueId)] : nil;
        [nextMapped addObject:(rm ? [XTIROperand useWithValueId:
                                                     (XTIRValueId)rm.unsignedLongLongValue]
                                  : nx)];
        }
    for (NSUInteger i = 0; i < phis.count; i++)
        [pbPhis addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                    result:pbVals[i]
                                                  operands:@[ [XTIROperand blockWithRef:H], initOp[i],
                                                              [XTIROperand blockWithRef:L], nextMapped[i] ]
                                                    dbgLoc:phis[i].dbgLoc]];

    // Remap helpers.
    void (^remapBlock)(XTIRBlock*, NSDictionary<NSNumber*, NSNumber*>*) =
        ^(XTIRBlock* bb, NSDictionary<NSNumber*, NSNumber*>* map) {
          NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
          [all addObjectsFromArray:bb.phiNodes];
          [all addObjectsFromArray:bb.instructions];
          if (bb.terminator)
              [all addObject:bb.terminator];
          for (XTIRInsn* insn in all)
              {
              BOOL ch = NO;
              NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
              for (NSUInteger k = 0; k < ops.count; k++)
                  {
                  if (ops[k].kind == XTIROperandKindUse)
                      {
                      NSNumber* n = map[@(ops[k].valueId)];
                      if (n)
                          {
                          ops[k] = [XTIROperand useWithValueId:(XTIRValueId)n.unsignedLongLongValue];
                          ch = YES;
                          }
                      }
                  }
              if (ch)
                  [insn replaceOperands:ops];
              }
        };

    // 3. In the body, current-iteration phi values become the new B-phis. B
    //    dominates every block of the region, so they are valid throughout.
    NSMutableDictionary<NSNumber*, NSNumber*>* bMap = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < phis.count; i++)
        bMap[phiIds[i]] = @(pbVals[i].valueId);
    for (XTIRBlock* rb in fn.blocks)
        if ([R containsObject:rb])
            remapBlock(rb, bMap);
    [B.phiNodes insertObjects:pbPhis
                    atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, pbPhis.count)]];

    // 4. Clone H's guard instructions to the bottom of L FIRST (while H still
    //    references the phis), with the phi values replaced by their
    //    next-iteration values; the clone of `cond` is c_B. Must precede the H
    //    remap below, which rewrites H's operands to the preheader inits.
    NSMutableDictionary<NSNumber*, NSNumber*>* gMap = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < phis.count; i++)
        if (nextMapped[i].kind == XTIROperandKindUse)
            gMap[phiIds[i]] = @(nextMapped[i].valueId); // mapped: see step 2
    XTIRValueId cBId = 0;
    for (XTIRInsn* insn in H.instructions)
        {
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:insn.operands.count];
        for (XTIROperand* op in insn.operands)
            {
            if (op.kind == XTIROperandKindUse)
                {
                NSNumber* n = gMap[@(op.valueId)];
                // An Imm-initialised phi's "next" can't be a value; such guards
                // were excluded because next is the back-edge Add (a Use).
                [ops addObject:(n ? [XTIROperand useWithValueId:(XTIRValueId)n.unsignedLongLongValue] : op)];
                }
            else
                [ops addObject:op];
            }
        XTIRValue *nr = nil, *nm = nil;
        if (insn.result)
            {
            XTIRValueId rid = [fn allocateValueId];
            nr = [[XTIRValue alloc] initWithValueId:rid
                                               type:insn.result.type
                                            defSite:[[XTIRDefSite alloc] initWithBlock:L insnIndex:L.instructions.count]];
            [fn registerValue:nr];
            gMap[@(insn.result.valueId)] = @(rid);
            }
        if (insn.memoryResult)
            {
            XTIRValueId mid = [fn allocateValueId];
            nm = [[XTIRValue alloc] initWithValueId:mid
                                               type:memTy
                                            defSite:[[XTIRDefSite alloc] initWithBlock:L insnIndex:L.instructions.count]];
            [fn registerValue:nm];
            }
        XTIRInsn* clone;
        if (XTIROpCarriesPredicate(insn.opcode))
            clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                              result:nr
                                            operands:ops
                                           predicate:insn.predicate
                                              dbgLoc:insn.dbgLoc];
        else
            clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode result:nr operands:ops dbgLoc:insn.dbgLoc];
        clone.memoryResult = nm;
        [L.instructions addObject:clone];
        if (insn.result && insn.result.valueId == c.condId)
            cBId = nr.valueId;
        }

    // 5. In H (the peeled test), phi values become their preheader init. (After
    //    the clone above, so the clone saw the original phi-referencing guard.)
    NSMutableDictionary<NSNumber*, XTIROperand*>* hReplace = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < phis.count; i++)
        hReplace[phiIds[i]] = initOp[i];
    for (XTIRInsn* insn in H.instructions)
        {
        BOOL ch = NO;
        NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
        for (NSUInteger k = 0; k < ops.count; k++)
            {
            if (ops[k].kind == XTIROperandKindUse)
                {
                XTIROperand* rep = hReplace[@(ops[k].valueId)];
                if (rep)
                    {
                    ops[k] = rep;
                    ch = YES;
                    }
                }
            }
        if (ch)
            [insn replaceOperands:ops];
        }

    // 6. L's terminator: the conditional back-edge to B (same orientation as H's).
    XTIRInsn* ht = H.terminator;
    XTIROperand* bt0 = (ht.operands[1].blockRef == B) ? [XTIROperand blockWithRef:B] : ht.operands[1];
    XTIROperand* bt1 = (ht.operands[2].blockRef == B) ? [XTIROperand blockWithRef:B] : ht.operands[2];
    [L resetTerminator];
    [L setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpCondBranch
                                               result:nil
                                             operands:@[ [XTIROperand useWithValueId:cBId], bt0, bt1 ]
                                            predicate:ht.predicate
                                               dbgLoc:ht.dbgLoc]];

    // 7. H keeps its (now init-using) guard + CondBranch; its phis are gone (it is
    //    entered only from the preheader now — the back-edge is B→B). When the
    //    guard holds on entry, H goes straight to B: E is then reached from L
    //    alone, and step 8 uses the latch's values in place of exit phis.
    [H.phiNodes removeAllObjects];
    if (c.entryTrue)
        {
        XTIRDbgLoc* dl = H.terminator.dbgLoc;
        [H resetTerminator];
        [H setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                                   result:nil
                                                 operands:@[ [XTIROperand blockWithRef:B] ]
                                                   dbgLoc:dl]];
        }

    // 7b. L's back-edge test exits to E too, so every phi E already has needs
    //     an L incoming. The value it took from H was defined outside the loop
    //     (a header phi read after the loop goes the exit-phi route below, which
    //     wants E phi-free, and the guard's results are used only in H), so it
    //     is the same on the new edge. Without this a checked downcast's join
    //     lost its hit value whenever the walk matched past the first parent.
    for (XTIRInsn* phi in E.phiNodes)
        {
        for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
            {
            if (phi.operands[k].kind == XTIROperandKindBlock && phi.operands[k].blockRef == H)
                {
                NSMutableArray<XTIROperand*>* ops = [phi.operands mutableCopy];
                [ops addObject:[XTIROperand blockWithRef:L]];
                [ops addObject:phi.operands[k + 1]];
                [phi replaceOperands:ops];
                break;
                }
            }
        }

    // 8. Exit phis for escaping carried values + rewrite post-loop uses.
    NSMutableArray<XTIRInsn*>* exitPhis = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, NSNumber*>* exitMap = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < phis.count; i++)
        {
        XTIRValueId pid = (XTIRValueId)[phiIds[i] unsignedLongLongValue];
        BOOL esc = NO;
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || [R containsObject:bb])
                continue;
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
            [all addObjectsFromArray:bb.phiNodes];
            [all addObjectsFromArray:bb.instructions];
            if (bb.terminator)
                [all addObject:bb.terminator];
            for (XTIRInsn* u in all)
                for (XTIROperand* o in u.operands)
                    if (o.kind == XTIROperandKindUse && o.valueId == pid)
                        {
                        esc = YES;
                        break;
                        }
            if (esc)
                break;
            }
        if (!esc)
            continue;
        if (c.entryTrue)
            {
            // No zero-trip path: after the loop the value is the latch's.
            exitMap[@(pid)] = @(nextMapped[i].valueId);   // a Use (checked when chosen)
            continue;
            }
        XTIRValueId rid = [fn allocateValueId];
        XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                     type:phis[i].result.type
                                                  defSite:[[XTIRDefSite alloc] initWithBlock:E insnIndex:0]];
        [fn registerValue:v];
        // The B→E incoming is the carried value on the exit edge, evaluated in B.
        // If that "next" operand is itself one of H's phis (e.g. `last = i`, whose
        // next is the IV phi), step 3 replaced that value in B with the new B-phi
        // and step 7 removed the old phi from H — so nextOp still names a now-dead
        // id. Remap it through bMap to the live B-phi. (A next that is a body value
        // like the IV's own `iv+1` Add is not in bMap and stays as-is.)
        XTIROperand* bInc = nextMapped[i];
        XTIRInsn* ep = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                 result:v
                                               operands:@[ [XTIROperand blockWithRef:H], initOp[i],
                                                           [XTIROperand blockWithRef:L], bInc ]
                                                 dbgLoc:nil];
        [E.phiNodes insertObject:ep atIndex:0];
        [exitPhis addObject:ep];
        exitMap[@(pid)] = @(rid);
        }
    if (exitMap.count)
        {
        for (XTIRBlock* bb in fn.blocks)
            {
            if (bb == H || [R containsObject:bb])
                continue;
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
            [all addObjectsFromArray:bb.phiNodes];
            [all addObjectsFromArray:bb.instructions];
            if (bb.terminator)
                [all addObject:bb.terminator];
            for (XTIRInsn* insn in all)
                {
                if ([exitPhis containsObject:insn])
                    continue;
                BOOL ch = NO;
                NSMutableArray<XTIROperand*>* ops = [insn.operands mutableCopy];
                for (NSUInteger k = 0; k < ops.count; k++)
                    {
                    if (ops[k].kind == XTIROperandKindUse)
                        {
                        NSNumber* n = exitMap[@(ops[k].valueId)];
                        if (n)
                            {
                            ops[k] = [XTIROperand useWithValueId:(XTIRValueId)n.unsignedLongLongValue];
                            ch = YES;
                            }
                        }
                    }
                if (ch)
                    [insn replaceOperands:ops];
                }
            }
        }
    }

@end
