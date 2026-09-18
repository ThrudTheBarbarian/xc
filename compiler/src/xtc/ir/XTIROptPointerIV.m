#import "XTIROptPointerIV.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"

@implementation XTIROptPointerIV

- (NSString*)passName
    {
    return @"pointer-iv";
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
    if (!prof.formsPointerInductionVars)
        return YES;
    if (getenv("XTPIV_OFF"))
        return YES;
    for (XTIRFunction* fn in mod.functions)
        {
        // One loop per function-scan pass; repeat until no more rewrites (a
        // function may hold several independent loops).
        for (int iter = 0; iter < 64; iter++)
            if (![self runOnceForFunction:fn])
                break;
        }
    return YES;
    }

// Resolve `vid` to (the induction phi + a constant element offset): iv → off 0;
// Add(x, const) / Add(const, x) where x resolves → off + const. Returns NO if
// not an affine function of `ivId`.
static BOOL affineOffset(XTIRValueId vid, XTIRValueId ivId,
                         NSDictionary<NSNumber*, XTIRInsn*>* defOf,
                         int64_t* offOut, int depth)
    {
    if (vid == ivId)
        {
        *offOut = 0;
        return YES;
        }
    if (depth > 16)
        return NO;
    XTIRInsn* d = defOf[@(vid)];
    if (!d)
        return NO;
    if (d.opcode == XTIROpAdd && d.operands.count >= 2)
        {
        XTIROperand *a = d.operands[0], *b = d.operands[1];
        int64_t inner, c;
        // x + const
        if (a.kind == XTIROperandKindUse && b.kind == XTIROperandKindImmI &&
            affineOffset(a.valueId, ivId, defOf, &inner, depth + 1))
            {
            *offOut = inner + b.intValue;
            return YES;
            }
        if (b.kind == XTIROperandKindUse && a.kind == XTIROperandKindImmI &&
            affineOffset(b.valueId, ivId, defOf, &inner, depth + 1))
            {
            *offOut = inner + a.intValue;
            return YES;
            }
        // x + const-Use (a Const insn)
        int64_t (^constOf)(XTIROperand*) = ^int64_t(XTIROperand* o) {
          if (o.kind != XTIROperandKindUse)
              return INT64_MIN;
          XTIRInsn* cd = defOf[@(o.valueId)];
          if (cd && cd.opcode == XTIROpConst && cd.operands.count >= 1 && cd.operands[0].kind == XTIROperandKindImmI)
              return cd.operands[0].intValue;
          return INT64_MIN;
        };
        if (a.kind == XTIROperandKindUse && affineOffset(a.valueId, ivId, defOf, &inner, depth + 1) &&
            (c = constOf(b)) != INT64_MIN)
            {
            *offOut = inner + c;
            return YES;
            }
        if (b.kind == XTIROperandKindUse && affineOffset(b.valueId, ivId, defOf, &inner, depth + 1) &&
            (c = constOf(a)) != INT64_MIN)
            {
            *offOut = inner + c;
            return YES;
            }
        }
    return NO;
    }

- (BOOL)runOnceForFunction:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSNumber*>* defBlkIdx = [NSMutableDictionary dictionary];
    for (NSUInteger bi = 0; bi < fn.blocks.count; bi++)
        {
        XTIRBlock* bb = fn.blocks[bi];
        for (XTIRInsn* phi in bb.phiNodes)
            if (phi.result)
                {
                defOf[@(phi.result.valueId)] = phi;
                defBlkIdx[@(phi.result.valueId)] = @(bi);
                }
        for (XTIRInsn* insn in bb.instructions)
            if (insn.result)
                {
                defOf[@(insn.result.valueId)] = insn;
                defBlkIdx[@(insn.result.valueId)] = @(bi);
                }
        }

    for (NSUInteger hi = 0; hi < fn.blocks.count; hi++)
        {
        XTIRBlock* H = fn.blocks[hi];
        if (H.phiNodes.count == 0)
            continue;
        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* guard = defOf[@(term.operands[0].valueId)];
        if (!guard || guard.opcode != XTIROpICmp || guard.operands.count < 2 ||
            guard.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRValueId ivId = guard.operands[0].valueId;
        XTIRInsn* ivPhi = nil;
        for (XTIRInsn* phi in H.phiNodes)
            if (phi.result && phi.result.valueId == ivId)
                {
                ivPhi = phi;
                break;
                }
        if (!ivPhi || ivPhi.operands.count != 4)
            continue;
        if (!XTIRTypeKindIsInteger(ivPhi.result.type.kind))
            continue;

        // Single-block latch B (B → H), the loop body; PH = the other incoming.
        XTIRBlock *t0 = term.operands[1].blockRef, *t1 = term.operands[2].blockRef;
        BOOL (^isLatch)(XTIRBlock*) = ^BOOL(XTIRBlock* b) {
          return b && b != H && b.terminator && b.terminator.opcode == XTIROpBranch &&
                 b.terminator.operands.count >= 1 && b.terminator.operands[0].blockRef == H;
        };
        XTIRBlock* B = isLatch(t0) ? t0 : (isLatch(t1) ? t1 : nil);
        if (!B)
            continue;
        NSUInteger biB = [fn.blocks indexOfObjectIdenticalTo:B];
        XTIRBlock* PH = (ivPhi.operands[0].blockRef == B) ? ivPhi.operands[2].blockRef : ivPhi.operands[0].blockRef;
        if (!PH || PH == B || PH == H)
            continue;

        // iv_next = Add(iv, stepConst) in B, the iv phi's back-edge. The step
        // can be an inline ImmI or a Const insn (ConstOperandFold runs AFTER this
        // pass, so `i + 1` may still reference a separate `Const #1` — resolve it
        // the same way affineOffset does).
        int64_t (^constVal)(XTIROperand*, BOOL*) = ^int64_t(XTIROperand* o, BOOL* ok) {
          *ok = NO;
          if (o.kind == XTIROperandKindImmI)
              {
              *ok = YES;
              return o.intValue;
              }
          if (o.kind == XTIROperandKindUse)
              {
              XTIRInsn* cd = defOf[@(o.valueId)];
              if (cd && cd.opcode == XTIROpConst && cd.operands.count >= 1 &&
                  cd.operands[0].kind == XTIROperandKindImmI)
                  {
                  *ok = YES;
                  return cd.operands[0].intValue;
                  }
              }
          return 0;
        };
        XTIROperand* ivBack = (ivPhi.operands[0].blockRef == B) ? ivPhi.operands[1] : ivPhi.operands[3];
        if (ivBack.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* ivNext = defOf[@(ivBack.valueId)];
        if (!ivNext || ivNext.opcode != XTIROpAdd || defBlkIdx[@(ivBack.valueId)].unsignedIntegerValue != biB)
            continue;
        int64_t step = 0;
        BOOL haveStep = NO, cok = NO;
        if (ivNext.operands[0].kind == XTIROperandKindUse && ivNext.operands[0].valueId == ivId)
            {
            step = constVal(ivNext.operands[1], &cok);
            haveStep = cok;
            }
        else if (ivNext.operands[1].kind == XTIROperandKindUse && ivNext.operands[1].valueId == ivId)
            {
            step = constVal(ivNext.operands[0], &cok);
            haveStep = cok;
            }
        if (!haveStep || step <= 0)
            continue;

        // Collect loop-invariant-base ElementAddrs at affine-iv indices, grouped
        // by base value. (Only fold when the base is a typed pointer defined
        // outside the loop, so the pointer phi's preheader incoming is available.)
        // Grouped by base, and iterated in FIRST-APPEARANCE order. The group
        // order decides which pointer phi is emitted first, so enumerating the
        // dictionary itself would make the printed IR depend on NSNumber hash
        // bucket order — stable for one Foundation, not across two, and not
        // reproducible for anyone diffing against this output.
        NSMutableDictionary<NSNumber*, NSMutableArray*>* groups = [NSMutableDictionary dictionary];
        NSMutableArray<NSNumber*>* groupOrder = [NSMutableArray array];
        for (XTIRInsn* insn in B.instructions)
            {
            if (insn.opcode != XTIROpElementAddr || !insn.result || insn.operands.count < 2)
                continue;
            XTIROperand *baseOp = insn.operands[0], *idxOp = insn.operands[1];
            if (baseOp.kind != XTIROperandKindUse || idxOp.kind != XTIROperandKindUse)
                continue;
            // Base must be loop-invariant: a function parameter (no def site — live
            // from entry), a value defined outside the loop, or an `AddrOf @sym` (a
            // constant address, hoisted to the preheader below). All three give the
            // pointer phi's PH incoming a value that dominates the loop.
            NSNumber* bBlk = defBlkIdx[@(baseOp.valueId)];
            XTIRInsn* bdef = defOf[@(baseOp.valueId)];
            BOOL isParam = !bBlk && !bdef;
            BOOL invariant = isParam ||
                             (bBlk && bBlk.unsignedIntegerValue != hi && bBlk.unsignedIntegerValue != biB);
            BOOL hoistableAddrOf = bdef && bdef.opcode == XTIROpAddrOf;
            if (!invariant && !hoistableAddrOf)
                continue;
            XTIRValue* bv = [fn valueForId:baseOp.valueId];
            if (!bv || bv.type.kind != XTIRTypeKindPtr || !bv.type.pointeeType)
                continue;
            int64_t off;
            if (!affineOffset(idxOp.valueId, ivId, defOf, &off, 0) || off < 0)
                continue;
            NSMutableArray* g = groups[@(baseOp.valueId)];
            if (!g)
                {
                g = [NSMutableArray array];
                groups[@(baseOp.valueId)] = g;
                [groupOrder addObject:@(baseOp.valueId)];
                }
            [g addObject:@[ insn, @(off) ]];
            }
        if (groups.count == 0)
            continue;
        // Register-pressure cap: each base becomes a loop-carried pointer phi,
        // and the unroller threads each through the unrolled copies (~2 live
        // values per pointer). Too many arrays overflow the GP home pool (9
        // callee-saved regs) and spill — a net loss.
        //
        // Re-measured 2026-09-18, best of five, reference compiler at -O3:
        //
        //   cap   array_map   mem_copy   struct_copy   matrix_mul   sieve
        //    2      15392       8253        16379        10082      32689
        //    3      12480       8138        16397         9996      32184
        //    4      12658       8548        15427        10005      33221
        //
        // 3 is the sweet spot and 2 was leaving a fifth of array_map on the
        // table: it reads a[i] and b[i] and writes c[i], so THREE bases, and at
        // a cap of 2 the whole loop kept recomputing `base + i*4` three times
        // per vector — and spilled the store address, because there is only one
        // address scratch. The earlier note said 4 "regresses badly"; measured
        // again it is only slightly worse than 3, so the cap is a tuning
        // parameter rather than a cliff. Re-measure before moving it.
        if (groups.count > 3)
            continue;

        XTIRType* ivTy = ivPhi.result.type;
        XTIRValue* (^newValIn)(XTIRType*, XTIRBlock*) = ^XTIRValue*(XTIRType* ty, XTIRBlock* blk) {
          XTIRValueId rid = [fn allocateValueId];
          XTIRValue* v = [[XTIRValue alloc] initWithValueId:rid
                                                       type:ty
                                                    defSite:[[XTIRDefSite alloc] initWithBlock:blk insnIndex:0]];
          [fn registerValue:v];
          return v;
        };
        XTIRValue* (^newVal)(XTIRType*) = ^XTIRValue*(XTIRType* ty) {
          return newValIn(ty, B);
        };

        // Where the induction variable STARTS — the iv phi's preheader incoming.
        // The pointer phi has to start at `base + ivInit`, not at `base`: the
        // accesses being replaced are at `iv + off`, and iv is `ivInit` on the
        // first iteration. Seeding with the bare base is right only when the
        // loop counts from zero, which is why `for (i = 0; ...)` was always
        // correct and `for (i = a; ...)` silently read from the start of the
        // array instead of from `a` (#1125 / field finding #12).
        XTIROperand* ivInit = (ivPhi.operands[0].blockRef == B) ? ivPhi.operands[3] : ivPhi.operands[1];
        BOOL iok = NO;
        int64_t initConst = constVal(ivInit, &iok);
        // A ZERO-EXTEND preserves a non-negative constant, so `ZExt(Const 0)`
        // starts at zero and needs no seed. Looked through HERE rather than in
        // constVal, which also decides the loop's step and must not start
        // accepting widened ones as a side effect. The self-hosted optimiser's
        // constValue already looks through ZExt, so without this the two emit
        // different (both correct) IR for `for (k = 0; ...)` — one with a
        // redundant `base + 0` — and opt-diff is a BYTE comparison.
        if (!iok && ivInit.kind == XTIROperandKindUse)
            {
            XTIRInsn* zd = defOf[@(ivInit.valueId)];
            if (zd && zd.opcode == XTIROpZExt && zd.operands.count >= 1)
                {
                BOOL zok = NO;
                int64_t zv = constVal(zd.operands[0], &zok);
                if (zok && zv >= 0)
                    {
                    initConst = zv;
                    iok = YES;
                    }
                }
            }
        BOOL initIsZero = (iok && initConst == 0);

        NSMutableArray<XTIRInsn*>* newBodyHead = [NSMutableArray array];                       // pointer steps + offset EAs
        NSMutableDictionary<NSNumber*, NSNumber*>* replace = [NSMutableDictionary dictionary]; // old EA result → new value
        NSMutableSet<XTIRInsn*>* removeEAs = [NSMutableSet set];

        for (NSNumber* baseKey in groupOrder)
            {
            XTIRValue* baseVal = [fn valueForId:baseKey.unsignedIntegerValue];
            XTIRType* ptrTy = baseVal.type;
            // If the base is an `AddrOf @sym` defined inside the loop, hoist it to
            // the preheader (it is a constant address) so the pointer phi's PH
            // incoming dominates the loop.
            XTIRInsn* bdef = defOf[baseKey];
            if (bdef && bdef.opcode == XTIROpAddrOf &&
                ([H.instructions containsObject:bdef] || [B.instructions containsObject:bdef]))
                {
                [H.instructions removeObjectIdenticalTo:bdef];
                [B.instructions removeObjectIdenticalTo:bdef];
                [PH.instructions addObject:bdef];
                }
            // p = phi[(PH, base + ivInit), (B, p_next)];  p_next = ElementAddr(p, step).
            //
            // `base + ivInit` is materialised in the PREHEADER when the loop does
            // not start at zero. It is available there by construction: it is the
            // iv phi's own incoming from that block, so it dominates the end of
            // it. Appending to `instructions` puts it before the terminator,
            // which is a separate property.
            XTIRValueId phIncoming = baseKey.unsignedIntegerValue;
            if (!initIsZero)
                {
                XTIRValue* seed = newValIn(ptrTy, PH);
                XTIROperand* idxOp = (ivInit.kind == XTIROperandKindImmI)
                                         ? [XTIROperand immIWithType:ivTy value:ivInit.intValue]
                                         : [XTIROperand useWithValueId:ivInit.valueId];
                XTIRInsn* seedInsn = [[XTIRInsn alloc] initWithOpcode:XTIROpElementAddr
                                                               result:seed
                                                             operands:@[ [XTIROperand useWithValueId:baseKey.unsignedIntegerValue], idxOp ]
                                                               dbgLoc:nil];
                [PH.instructions addObject:seedInsn];
                phIncoming = seed.valueId;
                }
            XTIRValue* p = newVal(ptrTy);
            XTIRValue* pNext = newVal(ptrTy);
            XTIRInsn* stepInsn = [[XTIRInsn alloc] initWithOpcode:XTIROpElementAddr
                                                           result:pNext
                                                         operands:@[ [XTIROperand useWithValueId:p.valueId],
                                                                     [XTIROperand immIWithType:ivTy
                                                                                         value:step] ]
                                                           dbgLoc:nil];
            [newBodyHead addObject:stepInsn];
            XTIRInsn* pPhi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                       result:p
                                                     operands:@[ [XTIROperand blockWithRef:PH], [XTIROperand useWithValueId:phIncoming],
                                                                 [XTIROperand blockWithRef:B], [XTIROperand useWithValueId:pNext.valueId] ]
                                                       dbgLoc:nil];
            [H.phiNodes addObject:pPhi];
            for (NSArray* acc in groups[baseKey])
                {
                XTIRInsn* E = acc[0];
                int64_t off = [acc[1] longLongValue];
                if (off == 0)
                    {
                    replace[@(E.result.valueId)] = @(p.valueId);
                    }
                else
                    {
                    XTIRValue* ea = newVal(ptrTy);
                    [newBodyHead addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpElementAddr
                                                                     result:ea
                                                                   operands:@[ [XTIROperand useWithValueId:p.valueId],
                                                                               [XTIROperand immIWithType:ivTy
                                                                                                   value:off] ]
                                                                     dbgLoc:nil]];
                    replace[@(E.result.valueId)] = @(ea.valueId);
                    }
                [removeEAs addObject:E];
                }
            }

        // Rebuild B: pointer steps + offset EAs first (they depend only on the
        // new phis / each other), then the surviving body with old EAs dropped.
        NSMutableArray<XTIRInsn*>* nb = [newBodyHead mutableCopy];
        for (XTIRInsn* insn in B.instructions)
            if (![removeEAs containsObject:insn])
                [nb addObject:insn];
        [B.instructions setArray:nb];

        // Rewire every use of a replaced ElementAddr result across the function.
        for (XTIRBlock* bb in fn.blocks)
            {
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
                    {
                    if (ops[k].kind != XTIROperandKindUse)
                        continue;
                    XTIRValueId rep = [replace[@(ops[k].valueId)] unsignedIntegerValue];
                    if (replace[@(ops[k].valueId)])
                        {
                        ops[k] = [XTIROperand useWithValueId:rep];
                        changed = YES;
                        }
                    }
                if (changed)
                    [insn replaceOperands:ops];
                }
            }
        return YES; // structure changed; recompute and look for the next loop
        }
    return NO;
    }

@end
