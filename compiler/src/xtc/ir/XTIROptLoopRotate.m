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
@property(nonatomic) XTIRBlock* B;       // latch/body (becomes the loop header)
@property(nonatomic) XTIRBlock* E;       // exit
@property(nonatomic) XTIRValueId condId; // the guard result feeding H's CondBranch
@end
@implementation XTLoopRotCand
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
        if (!c)
            break;
        [self apply:c inFunction:fn];
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
        if (hasVecPhi)
            continue;
        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRValueId condId = term.operands[0].valueId;
        if (defBlk[@(condId)] != H)
            continue; // guard must be computed in H

        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        if (!t0 || !t1 || t0 == t1)
            continue;
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
        if (B == E || !E)
            continue;

        // B's only predecessor is H; H's predecessors are exactly {PH, B}.
        if (predsOf(B, fn).count != 1)
            continue; // == {H} (B latches to H)
        NSArray<XTIRBlock*>* hp = predsOf(H, fn);
        if (hp.count != 2 || ![hp containsObject:B])
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
                if (o.kind == XTIROperandKindUse && defBlk[@(o.valueId)] == B)
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
                    phi.operands[i].blockRef == B &&
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
                if (bb == H || bb == B)
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

        XTLoopRotCand* c = [XTLoopRotCand new];
        c.H = H;
        c.B = B;
        c.E = E;
        c.condId = condId;
        return c;
        }
    return nil;
    }

- (void)apply:(XTLoopRotCand*)c inFunction:(XTIRFunction*)fn
    {
    XTIRBlock *H = c.H, *B = c.B, *E = c.E;
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
            if (phi.operands[k].blockRef == B)
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
                                                              [XTIROperand blockWithRef:B], nextMapped[i] ]
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

    // 3. In B's body, current-iteration phi values become the new B-phis.
    NSMutableDictionary<NSNumber*, NSNumber*>* bMap = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < phis.count; i++)
        bMap[phiIds[i]] = @(pbVals[i].valueId);
    remapBlock(B, bMap);
    [B.phiNodes insertObjects:pbPhis
                    atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, pbPhis.count)]];

    // 4. Clone H's guard instructions to the bottom of B FIRST (while H still
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
                                            defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:B.instructions.count]];
            [fn registerValue:nr];
            gMap[@(insn.result.valueId)] = @(rid);
            }
        if (insn.memoryResult)
            {
            XTIRValueId mid = [fn allocateValueId];
            nm = [[XTIRValue alloc] initWithValueId:mid
                                               type:memTy
                                            defSite:[[XTIRDefSite alloc] initWithBlock:B insnIndex:B.instructions.count]];
            [fn registerValue:nm];
            }
        XTIRInsn* clone;
        if (insn.opcode == XTIROpICmp || insn.opcode == XTIROpFCmp)
            clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode
                                              result:nr
                                            operands:ops
                                           predicate:insn.predicate
                                              dbgLoc:insn.dbgLoc];
        else
            clone = [[XTIRInsn alloc] initWithOpcode:insn.opcode result:nr operands:ops dbgLoc:insn.dbgLoc];
        clone.memoryResult = nm;
        [B.instructions addObject:clone];
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

    // 6. B's terminator: the conditional back-edge (same orientation as H's).
    XTIRInsn* ht = H.terminator;
    XTIROperand* bt0 = (ht.operands[1].blockRef == B) ? [XTIROperand blockWithRef:B] : ht.operands[1];
    XTIROperand* bt1 = (ht.operands[2].blockRef == B) ? [XTIROperand blockWithRef:B] : ht.operands[2];
    [B resetTerminator];
    [B setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpCondBranch
                                               result:nil
                                             operands:@[ [XTIROperand useWithValueId:cBId], bt0, bt1 ]
                                            predicate:ht.predicate
                                               dbgLoc:ht.dbgLoc]];

    // 7. H keeps its (now init-using) guard + CondBranch; its phis are gone (it is
    //    entered only from the preheader now — the back-edge is B→B).
    [H.phiNodes removeAllObjects];

    // 8. Exit phis for escaping carried values + rewrite post-loop uses.
    NSMutableArray<XTIRInsn*>* exitPhis = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, NSNumber*>* exitMap = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < phis.count; i++)
        {
        XTIRValueId pid = (XTIRValueId)[phiIds[i] unsignedLongLongValue];
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
                                                           [XTIROperand blockWithRef:B], bInc ]
                                                 dbgLoc:nil];
        [E.phiNodes insertObject:ep atIndex:0];
        [exitPhis addObject:ep];
        exitMap[@(pid)] = @(rid);
        }
    if (exitMap.count)
        {
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
