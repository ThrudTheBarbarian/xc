#import "XTIROptOuterVectorize.h"
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

// The role of a value in the nest being vectorised.
typedef NS_ENUM(NSInteger, XTOVRole) {
    XTOVUniform = 0, // the same for every j: stays scalar
    XTOVIndex,       // j + (uniform): a scalar element index
    XTOVAddr,        // ElementAddr(uniform base, index): a scalar lane-0 address
    XTOVVector,      // depends on j any other way: becomes a vector
};

@implementation XTIROptOuterVectorize

- (NSString*)passName
    {
    return @"outer-vectorize";
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
    if (!prof.vectorizesLoops)
        return YES;
    for (XTIRFunction* fn in mod.functions)
        for (int guard = 0; guard < 16; guard++)
            if (![self vectorizeOneIn:fn])
                break;
    return YES;
    }

// An integer constant: an immediate, or a Const seen through one ZExt.
static BOOL ovConst(XTIROperand* o, NSDictionary<NSNumber*, XTIRInsn*>* defOf, int64_t* out)
    {
    if (o.kind == XTIROperandKindImmI)
        {
        *out = o.intValue;
        return YES;
        }
    if (o.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* d = defOf[@(o.valueId)];
    if (d && d.opcode == XTIROpZExt && d.operands.count >= 1 && d.operands[0].kind == XTIROperandKindUse)
        d = defOf[@(d.operands[0].valueId)];
    if (d && d.opcode == XTIROpConst && d.operands.count >= 1 && d.operands[0].kind == XTIROperandKindImmI)
        {
        *out = d.operands[0].intValue;
        return YES;
        }
    return NO;
    }

// Header instructions a counted loop may carry: constants, their widening,
// and the guard compare.
static BOOL ovHeaderInsnsOk(XTIRBlock* H)
    {
    for (XTIRInsn* i in H.instructions)
        if (i.opcode != XTIROpConst && i.opcode != XTIROpZExt && i.opcode != XTIROpICmp)
            return NO;
    return YES;
    }

static BOOL ovArith(XTIROpcode op)
    {
    return op == XTIROpAdd || op == XTIROpSub || op == XTIROpMul ||
           op == XTIROpAnd || op == XTIROpOr || op == XTIROpXor;
    }

static XTIROpcode ovVecOp(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpAdd: return XTIROpVAdd;
    case XTIROpSub: return XTIROpVSub;
    case XTIROpMul: return XTIROpVMul;
    case XTIROpAnd: return XTIROpVAnd;
    case XTIROpOr: return XTIROpVOr;
    default: return XTIROpVXor;
        }
    }

static BOOL ovSameType(XTIRType* a, XTIRType* b)
    {
    return a && b && a.kind == b.kind && a.byteWidth == b.byteWidth;
    }

// The array a pointer is derived from: walk ElementAddr / FieldAddr bases to
// an AddrOf of a local or a global. nil when it is not one of those, which
// makes the pass decline — it cannot then prove a store apart from the loads.
static NSString* ovRoot(XTIRValueId v, NSDictionary<NSNumber*, XTIRInsn*>* defOf)
    {
    for (int hop = 0; hop < 16; hop++)
        {
        XTIRInsn* d = defOf[@(v)];
        if (!d || d.operands.count < 1)
            return nil;
        if (d.opcode == XTIROpAddrOf)
            {
            XTIROperand* o = d.operands[0];
            if (o.kind == XTIROperandKindUse)
                return [NSString stringWithFormat:@"u%lu", (unsigned long)o.valueId];
            if (o.kind == XTIROperandKindSym)
                return [NSString stringWithFormat:@"s%lu", (unsigned long)o.symbolId];
            return nil;
            }
        if ((d.opcode == XTIROpElementAddr || d.opcode == XTIROpFieldAddr) &&
            d.operands[0].kind == XTIROperandKindUse)
            {
            v = d.operands[0].valueId;
            continue;
            }
        return nil;
        }
    return nil;
    }

- (BOOL)vectorizeOneIn:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, XTIRBlock*>* defBlk = [NSMutableDictionary dictionary];
    NSMapTable<XTIRBlock*, NSMutableArray<XTIRBlock*>*>* preds = [NSMapTable strongToStrongObjectsMapTable];
    for (XTIRBlock* b in fn.blocks)
        [preds setObject:[NSMutableArray array] forKey:b];
    for (XTIRBlock* b in fn.blocks)
        {
        for (XTIRInsn* p in b.phiNodes)
            if (p.result)
                {
                defOf[@(p.result.valueId)] = p;
                defBlk[@(p.result.valueId)] = b;
                }
        for (XTIRInsn* i in b.instructions)
            if (i.result)
                {
                defOf[@(i.result.valueId)] = i;
                defBlk[@(i.result.valueId)] = b;
                }
        for (XTIROperand* o in b.terminator.operands)
            if (o.kind == XTIROperandKindBlock && o.blockRef &&
                ![[preds objectForKey:o.blockRef] containsObject:b])
                [[preds objectForKey:o.blockRef] addObject:b];
        }

    for (XTIRBlock* Hj in fn.blocks)
        {
        // ── The j loop: header Hj (one phi, j), body Bj straight into Hk ──
        XTIRInsn* tj = Hj.terminator;
        if (!tj || tj.opcode != XTIROpCondBranch || tj.operands.count < 3 || Hj.phiNodes.count != 1)
            continue;
        if (!ovHeaderInsnsOk(Hj) || tj.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* gj = defOf[@(tj.operands[0].valueId)];
        XTIRInsn* jPhi = Hj.phiNodes[0];
        if (!gj || gj.opcode != XTIROpICmp || gj.predicate != XTIRICmpULT || gj.operands.count < 2 ||
            gj.operands[0].kind != XTIROperandKindUse || gj.operands[0].valueId != jPhi.result.valueId ||
            jPhi.operands.count != 4)
            continue;
        int64_t trip = 0;
        if (!ovConst(gj.operands[1], defOf, &trip))
            continue;
        XTIRBlock* Bj = tj.operands[1].blockRef;
        if (!Bj || Bj == Hj || [[preds objectForKey:Bj] count] != 1)
            continue;
        BOOL bjOk = Bj.phiNodes.count == 0 && Bj.terminator && Bj.terminator.opcode == XTIROpBranch;
        for (XTIRInsn* i in Bj.instructions)
            if (i.opcode != XTIROpConst && i.opcode != XTIROpZExt)
                bjOk = NO;
        if (!bjOk)
            continue;

        // ── The k loop: header Hk (k and one accumulator s), body Bk, exit Ek ──
        XTIRBlock* Hk = Bj.terminator.operands[0].blockRef;
        if (!Hk || Hk == Hj || Hk.phiNodes.count != 2 || !ovHeaderInsnsOk(Hk))
            continue;
        XTIRInsn* tk = Hk.terminator;
        if (!tk || tk.opcode != XTIROpCondBranch || tk.operands.count < 3 || tk.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* gk = defOf[@(tk.operands[0].valueId)];
        if (!gk || gk.opcode != XTIROpICmp || gk.operands.count < 2 || gk.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRBlock* Bk = tk.operands[1].blockRef;
        XTIRBlock* Ek = tk.operands[2].blockRef;
        if (!Bk || !Ek || Bk == Hk || Ek == Hk || Bk == Ek)
            continue;
        if (!Bk.terminator || Bk.terminator.opcode != XTIROpBranch || Bk.terminator.operands[0].blockRef != Hk)
            continue;
        if (!Ek.terminator || Ek.terminator.opcode != XTIROpBranch || Ek.terminator.operands[0].blockRef != Hj)
            continue;
        NSArray<XTIRBlock*>* pk = [preds objectForKey:Hk];
        if ([[preds objectForKey:Bk] count] != 1 || [[preds objectForKey:Ek] count] != 1 ||
            pk.count != 2 || ![pk containsObject:Bj] || ![pk containsObject:Bk])
            continue;
        if (Bk.phiNodes.count != 0 || Ek.phiNodes.count != 0)
            continue;
        NSArray<XTIRBlock*>* pj = [preds objectForKey:Hj];
        if (pj.count != 2 || ![pj containsObject:Ek])
            continue;

        // j: starts at 0, steps by 1 in Ek, and the trip divides by the lanes.
        XTIROperand *jInit = nil, *jBack = nil;
        for (NSUInteger q = 0; q + 1 < 4; q += 2)
            {
            if (jPhi.operands[q].blockRef == Ek)
                jBack = jPhi.operands[q + 1];
            else
                jInit = jPhi.operands[q + 1];
            }
        int64_t j0 = -1;
        if (!jInit || !jBack || !ovConst(jInit, defOf, &j0) || j0 != 0 || jBack.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* jNext = defOf[@(jBack.valueId)];
        int64_t jStep = 0;
        if (!jNext || jNext.opcode != XTIROpAdd || defBlk[@(jBack.valueId)] != Ek ||
            jNext.operands[0].kind != XTIROperandKindUse || jNext.operands[0].valueId != jPhi.result.valueId ||
            !ovConst(jNext.operands[1], defOf, &jStep) || jStep != 1)
            continue;

        // k and s: k is the phi the k guard tests; s is the other.
        XTIRInsn *kPhi = nil, *sPhi = nil;
        for (XTIRInsn* p in Hk.phiNodes)
            {
            if (p.result && p.result.valueId == gk.operands[0].valueId)
                kPhi = p;
            else
                sPhi = p;
            }
        if (!kPhi || !sPhi || !sPhi.result || sPhi.operands.count != 4)
            continue;
        XTIRType* laneTy = sPhi.result.type;
        if (!laneTy || !XTIRTypeKindIsInteger(laneTy.kind) || laneTy.byteWidth != 4)
            continue;
        // The width this function may use: a dispatch clone's own level
        // (32 bytes for avx2, 64 for avx512), else the target's. It was a
        // fixed 16, which left x86-64 at four lanes under AVX-512 (bug 644).
        NSUInteger vb = fn.simdLaneBytes ? fn.simdLaneBytes
                                         : (self.profile ?: [XTIROptTargetProfile conservativeProfile]).vectorLaneBytes;
        vb = vb == 64 ? 64 : vb == 32 ? 32 : 16;
        NSUInteger lanes = vb / laneTy.byteWidth;
        if (trip <= 0 || trip % (int64_t)lanes != 0)
            continue;
        XTIROperand *sInit = nil, *sBack = nil;
        for (NSUInteger q = 0; q + 1 < 4; q += 2)
            {
            if (sPhi.operands[q].blockRef == Bk)
                sBack = sPhi.operands[q + 1];
            else
                sInit = sPhi.operands[q + 1];
            }
        if (!sInit || !sBack || sBack.kind != XTIROperandKindUse)
            continue;

        // ── Classify Bk then Ek ──
        XTIRValueId jId = jPhi.result.valueId;
        NSMutableDictionary<NSNumber*, NSNumber*>* role = [NSMutableDictionary dictionary];
        role[@(jId)] = @(XTOVIndex);
        role[@(sPhi.result.valueId)] = @(XTOVVector);
        XTOVRole (^roleOf)(XTIROperand*) = ^XTOVRole(XTIROperand* o) {
          if (o.kind != XTIROperandKindUse)
              return XTOVUniform;
          NSNumber* r = role[@(o.valueId)];
          return r ? (XTOVRole)r.integerValue : XTOVUniform;
        };
        NSMutableArray<NSString*>* loadRoots = [NSMutableArray array];
        NSMutableArray<NSString*>* storeRoots = [NSMutableArray array];
        BOOL ok = YES;
        NSUInteger vecStores = 0;
        for (XTIRBlock* blk in @[ Bk, Ek ])
            {
            for (XTIRInsn* i in blk.instructions)
                {
                if (i == jNext)
                    continue;
                XTIROpcode op = i.opcode;
                BOOL anyNonUniform = NO;
                for (XTIROperand* o in i.operands)
                    if (roleOf(o) != XTOVUniform)
                        anyNonUniform = YES;
                if (op == XTIROpLoad)
                    {
                    if (i.operands.count < 1 || i.operands[0].kind != XTIROperandKindUse)
                        {
                        ok = NO;
                        break;
                        }
                    NSString* root = ovRoot(i.operands[0].valueId, defOf);
                    if (!root)
                        {
                        ok = NO;
                        break;
                        }
                    [loadRoots addObject:root];
                    XTOVRole ar = roleOf(i.operands[0]);
                    if (ar == XTOVUniform)
                        continue; // a j-independent load stays scalar
                    if (ar != XTOVAddr || !ovSameType(i.result.type, laneTy))
                        {
                        ok = NO;
                        break;
                        }
                    role[@(i.result.valueId)] = @(XTOVVector);
                    continue;
                    }
                if (op == XTIROpStore)
                    {
                    if (blk != Ek || i.operands.count < 2 || roleOf(i.operands[0]) != XTOVAddr ||
                        roleOf(i.operands[1]) != XTOVVector || i.operands[0].kind != XTIROperandKindUse)
                        {
                        ok = NO;
                        break;
                        }
                    NSString* root = ovRoot(i.operands[0].valueId, defOf);
                    if (!root)
                        {
                        ok = NO;
                        break;
                        }
                    [storeRoots addObject:root];
                    vecStores++;
                    continue;
                    }
                if (!i.result || i.memoryResult)
                    {
                    ok = NO;
                    break;
                    }
                if (!anyNonUniform)
                    continue; // uniform: stays scalar
                if (op == XTIROpAdd && i.operands.count == 2 &&
                    ((roleOf(i.operands[0]) == XTOVIndex && roleOf(i.operands[1]) == XTOVUniform) ||
                     (roleOf(i.operands[1]) == XTOVIndex && roleOf(i.operands[0]) == XTOVUniform)))
                    {
                    role[@(i.result.valueId)] = @(XTOVIndex);
                    continue;
                    }
                if (op == XTIROpElementAddr && i.operands.count == 2 && roleOf(i.operands[0]) == XTOVUniform &&
                    roleOf(i.operands[1]) == XTOVIndex)
                    {
                    XTIRType* pt = i.result.type;
                    if (!pt || pt.kind != XTIRTypeKindPtr || !ovSameType(pt.pointeeType, laneTy))
                        {
                        ok = NO;
                        break;
                        }
                    role[@(i.result.valueId)] = @(XTOVAddr);
                    continue;
                    }
                if (ovArith(op) && i.operands.count == 2 && ovSameType(i.result.type, laneTy))
                    {
                    XTOVRole r0 = roleOf(i.operands[0]), r1 = roleOf(i.operands[1]);
                    if ((r0 == XTOVVector || r0 == XTOVUniform) && (r1 == XTOVVector || r1 == XTOVUniform) &&
                        i.operands[0].kind == XTIROperandKindUse && i.operands[1].kind == XTIROperandKindUse)
                        {
                        role[@(i.result.valueId)] = @(XTOVVector);
                        continue;
                        }
                    }
                ok = NO;
                break;
                }
            if (!ok)
                break;
            }
        if (!ok || vecStores == 0 || roleOf(sBack) != XTOVVector || defBlk[@(sBack.valueId)] != Bk)
            continue;
        // The stores must be provably apart from every load.
        for (NSString* sr in storeRoots)
            if ([loadRoots containsObject:sr])
                ok = NO;
        if (!ok)
            continue;
        // No non-uniform value may be read outside Bk / Ek (other than j's
        // guard and step, and s's own phi), and an index or address only as one.
        for (XTIRBlock* b in fn.blocks)
            {
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:b.phiNodes];
            [all addObjectsFromArray:b.instructions];
            if (b.terminator)
                [all addObject:b.terminator];
            for (XTIRInsn* u in all)
                {
                BOOL inside = (b == Bk || b == Ek);
                for (NSUInteger q = 0; q < u.operands.count; q++)
                    {
                    XTIROperand* o = u.operands[q];
                    XTOVRole r = roleOf(o);
                    if (r == XTOVUniform)
                        continue;
                    if (o.valueId == jId && (u == gj || u == jNext))
                        continue;
                    if (u == sPhi)
                        continue;
                    if (!inside)
                        {
                        ok = NO;
                        break;
                        }
                    if (r == XTOVIndex &&
                        !((u.opcode == XTIROpAdd && u.result && roleOf([XTIROperand useWithValueId:u.result.valueId]) == XTOVIndex) ||
                          (u.opcode == XTIROpElementAddr && q == 1)))
                        ok = NO;
                    if (r == XTOVAddr && !((u.opcode == XTIROpLoad || u.opcode == XTIROpStore) && q == 0))
                        ok = NO;
                    if (!ok)
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

        // ── Rewrite ──
        XTIRType* vecTy = [XTIRType vecWithLane:laneTy bytes:(uint32_t)(lanes * laneTy.byteWidth)];
        XTIRValue* (^newVal)(XTIRType*, XTIRBlock*) = ^XTIRValue*(XTIRType* ty, XTIRBlock* blk) {
          XTIRValueId rid = [fn allocateValueId];
          XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                       type:ty
                                                    defSite:[[XTIRDefSite alloc] initWithBlock:blk insnIndex:0]];
          [fn registerValue:v];
          return v;
        };
        NSMutableDictionary<NSNumber*, NSNumber*>* vmap = [NSMutableDictionary dictionary];
        // The accumulator starts as the broadcast of its scalar seed, in Bj.
        XTIRValue* vInit = newVal(vecTy, Bj);
        [Bj.instructions addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                             result:vInit
                                                           operands:@[ sInit ]
                                                             dbgLoc:nil]];
        XTIRValue* vAcc = newVal(vecTy, Hk);
        vmap[@(sPhi.result.valueId)] = @(vAcc.valueId);

        for (XTIRBlock* blk in @[ Bk, Ek ])
            {
            NSMutableArray<XTIRInsn*>* nb = [NSMutableArray array];
            NSMutableDictionary<NSNumber*, NSNumber*>* splats = [NSMutableDictionary dictionary];
            XTIROperand* (^vecOperand)(XTIROperand*) = ^XTIROperand*(XTIROperand* o) {
              if (roleOf(o) == XTOVVector)
                  return [XTIROperand useWithValueId:[vmap[@(o.valueId)] unsignedIntegerValue]];
              NSNumber* have = splats[@(o.valueId)];
              if (!have)
                  {
                  XTIRValue* sv = newVal(vecTy, blk);
                  [nb addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpVSplat
                                                          result:sv
                                                        operands:@[ o ]
                                                          dbgLoc:nil]];
                  have = @(sv.valueId);
                  splats[@(o.valueId)] = have;
                  }
              return [XTIROperand useWithValueId:have.unsignedIntegerValue];
            };
            for (XTIRInsn* i in blk.instructions)
                {
                if (i == jNext)
                    {
                    [i replaceOperands:@[ i.operands[0], [XTIROperand immIWithType:jPhi.result.type value:(int64_t)lanes] ]];
                    [nb addObject:i];
                    continue;
                    }
                if (i.opcode == XTIROpStore)
                    {
                    NSMutableArray<XTIROperand*>* ops = [i.operands mutableCopy];
                    ops[1] = vecOperand(i.operands[1]);
                    XTIRInsn* vs = [[XTIRInsn alloc] initWithOpcode:XTIROpVStore
                                                             result:nil
                                                           operands:ops
                                                             dbgLoc:i.dbgLoc];
                    vs.memoryResult = i.memoryResult;
                    [nb addObject:vs];
                    continue;
                    }
                if (!i.result || roleOf([XTIROperand useWithValueId:i.result.valueId]) != XTOVVector)
                    {
                    [nb addObject:i];
                    continue;
                    }
                XTIRValue* vr = newVal(vecTy, blk);
                if (i.opcode == XTIROpLoad)
                    {
                    XTIRInsn* vl = [[XTIRInsn alloc] initWithOpcode:XTIROpVLoad
                                                             result:vr
                                                           operands:i.operands
                                                             dbgLoc:i.dbgLoc];
                    vl.memoryResult = i.memoryResult;
                    [nb addObject:vl];
                    }
                else
                    {
                    XTIROperand* a = vecOperand(i.operands[0]);
                    XTIROperand* b = vecOperand(i.operands[1]);
                    [nb addObject:[[XTIRInsn alloc] initWithOpcode:ovVecOp(i.opcode)
                                                            result:vr
                                                          operands:@[ a, b ]
                                                            dbgLoc:i.dbgLoc]];
                    }
                vmap[@(i.result.valueId)] = @(vr.valueId);
                }
            [blk.instructions setArray:nb];
            }

        // The accumulator phi becomes the vector one.
        XTIRBlock* initBlk = (sPhi.operands[0].blockRef == Bk) ? sPhi.operands[2].blockRef : sPhi.operands[0].blockRef;
        XTIRInsn* vPhi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                   result:vAcc
                                                 operands:@[ [XTIROperand blockWithRef:initBlk], [XTIROperand useWithValueId:vInit.valueId],
                                                             [XTIROperand blockWithRef:Bk],
                                                             [XTIROperand useWithValueId:[vmap[@(sBack.valueId)] unsignedIntegerValue]] ]
                                                   dbgLoc:sPhi.dbgLoc];
        NSUInteger at = [Hk.phiNodes indexOfObjectIdenticalTo:sPhi];
        [Hk.phiNodes replaceObjectAtIndex:at withObject:vPhi];
        return YES;
        }
    return NO;
    }

@end
