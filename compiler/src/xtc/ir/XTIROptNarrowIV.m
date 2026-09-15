#import "XTIROptNarrowIV.h"
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

@implementation XTIROptNarrowIV

- (NSString*)passName
    {
    return @"narrow-iv";
    }
- (NSInteger)minOptLevel
    {
    return 1;
    }

// Resolve an operand to a constant integer, following Const and width casts
// (ZExt/SExt/Bitcast) that preserve a non-negative value.
static BOOL constVal(XTIROperand* op, NSDictionary<NSNumber*, XTIRInsn*>* defOf, int64_t* out)
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
        if (!def || def.operands.count < 1)
            return NO;
        if (def.opcode == XTIROpConst)
            return (def.operands[0].kind == XTIROperandKindImmI)
                       ? (out ? (*out = def.operands[0].intValue, YES) : YES)
                       : NO;
        if ((def.opcode == XTIROpZExt || def.opcode == XTIROpSExt || def.opcode == XTIROpBitcast) && def.operands[0].kind == XTIROperandKindUse)
            {
            cur = def.operands[0].valueId;
            continue;
            }
        return NO;
        }
    return NO;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptTargetProfile* prof = self.profile ?: [XTIROptTargetProfile conservativeProfile];
    if (!prof.narrowsInductionVars)
        return YES;
    if (getenv("NIV_OFF"))
        return YES; // A/B measurement escape hatch
    for (XTIRFunction* fn in mod.functions)
        // fixpoint: one IV per pass
        while ([self narrowOneIVInFunction:fn])
            {
            }
    return YES;
    }

// Attempt to narrow a single induction variable; returns YES if one was
// narrowed (caller re-runs to catch sibling IVs / nested loops).
- (BOOL)narrowOneIVInFunction:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result)
                defOf[@(p.result.valueId)] = p;
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                defOf[@(i.result.valueId)] = i;
        }

    for (XTIRBlock* H in fn.blocks)
        {
        if (H.phiNodes.count == 0)
            continue;
        XTIRInsn* term = H.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 1)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* cmp = defOf[@(term.operands[0].valueId)];
        if (!cmp || cmp.opcode != XTIROpICmp || cmp.operands.count != 2)
            continue;
        if ([H.instructions indexOfObjectIdenticalTo:cmp] == NSNotFound)
            continue; // guard computed in H
        XTIRICmpPredicate pred = (XTIRICmpPredicate)cmp.predicate;
        if (pred != XTIRICmpSLT && pred != XTIRICmpSLE && pred != XTIRICmpULT && pred != XTIRICmpULE)
            continue;
        if (cmp.operands[0].kind != XTIROperandKindUse)
            continue; // iv on the left
        XTIRValueId ivId = cmp.operands[0].valueId;

        // The IV must be a header phi in H.
        XTIRInsn* ivPhi = nil;
        for (XTIRInsn* p in H.phiNodes)
            if (p.result && p.result.valueId == ivId)
                {
                ivPhi = p;
                break;
                }
        if (!ivPhi || !ivPhi.result || ivPhi.operands.count != 4)
            continue;
        if (!XTIRTypeKindIsInteger(ivPhi.result.type.kind))
            continue;
        NSUInteger curW = ivPhi.result.type.byteWidth;

        int64_t bound;
        if (!constVal(cmp.operands[1], defOf, &bound) || bound < 0)
            continue;

        // Parse the two phi incomings: one is the loop-entry init (const c0>=0),
        // the other is the latch value Add(iv, step) / Add(step, iv), step>0.
        XTIRBlock* phBlk = nil;
        int64_t c0 = 0;
        BOOL haveInit = NO;
        XTIRInsn* incAdd = nil;
        XTIRValueId nextId = 0;
        int64_t step = 0;
        BOOL haveNext = NO;
        for (int k = 0; k < 2; k++)
            {
            XTIROperand* blkOp = ivPhi.operands[2 * k];
            XTIROperand* useOp = ivPhi.operands[2 * k + 1];
            if (blkOp.kind != XTIROperandKindBlock || useOp.kind != XTIROperandKindUse)
                {
                haveInit = NO;
                break;
                }
            XTIRInsn* d = defOf[@(useOp.valueId)];
            if (d && d.opcode == XTIROpAdd && d.operands.count == 2)
                {
                int64_t s = 0;
                BOOL formsInc = NO; // next = Add(iv, const) / Add(const, iv)
                if (d.operands[0].kind == XTIROperandKindUse && d.operands[0].valueId == ivId && constVal(d.operands[1], defOf, &s))
                    formsInc = YES;
                else if (d.operands[1].kind == XTIROperandKindUse && d.operands[1].valueId == ivId && constVal(d.operands[0], defOf, &s))
                    formsInc = YES;
                if (formsInc && s > 0)
                    {
                    incAdd = d;
                    nextId = useOp.valueId;
                    step = s;
                    haveNext = YES;
                    continue;
                    }
                }
            // else: init incoming
            if (constVal(useOp, defOf, &c0) && c0 >= 0)
                {
                phBlk = blkOp.blockRef;
                haveInit = YES;
                }
            else
                {
                haveInit = NO;
                break;
                }
            }
        if (!haveInit || !haveNext || !phBlk || !incAdd)
            continue;

        int64_t maxV = bound + step; // safe upper bound on any IV value held
        NSUInteger newW = (maxV <= 0xFF) ? 1 : (maxV <= 0xFFFF) ? 2
                                                                : 4;
        if (newW >= curW)
            continue; // already minimal — nothing to do

        // Classify every DIRECT use of iv and next. iv is an integer, so in an
        // ElementAddr it can only be an index (never the base pointer). A
        // ZExt/SExt of iv keeps the same logical value, so it stays correct
        // after narrowing. Any other direct use observes the wide bit pattern.
        BOOL ok = YES;
        for (XTIRBlock* bb in fn.blocks)
            {
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
            [all addObjectsFromArray:bb.instructions];
            if (bb.terminator)
                [all addObject:bb.terminator];
            for (XTIRInsn* insn in all)
                {
                for (XTIROperand* o in insn.operands)
                    {
                    if (o.kind != XTIROperandKindUse)
                        continue;
                    if (o.valueId == ivId)
                        {
                        BOOL allow = (insn == cmp) || (insn == incAdd) || insn.opcode == XTIROpElementAddr || insn.opcode == XTIROpZExt || insn.opcode == XTIROpSExt;
                        if (!allow)
                            {
                            ok = NO;
                            break;
                            }
                        }
                    else if (o.valueId == nextId)
                        {
                        BOOL allow = (insn == ivPhi) || insn.opcode == XTIROpElementAddr || insn.opcode == XTIROpZExt || insn.opcode == XTIROpSExt;
                        if (!allow)
                            {
                            ok = NO;
                            break;
                            }
                        }
                    }
                if (!ok)
                    break;
                }
            if (!ok)
                break;
            }
        if (!ok)
            continue;

        // ── Transform ────────────────────────────────────────────────────────
        XTIRType* nt = (newW == 1) ? [XTIRType u8Type] : [XTIRType u16Type];
        XTIRICmpPredicate np = (pred == XTIRICmpSLT)   ? XTIRICmpULT
                               : (pred == XTIRICmpSLE) ? XTIRICmpULE
                                                       : pred;

        XTIRValue* newIV = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                         type:nt
                                                      defSite:[[XTIRDefSite alloc] initWithBlock:H insnIndex:0]];
        [fn registerValue:newIV];
        XTIRBlock* incBlk = nil;
        for (XTIRBlock* bb in fn.blocks)
            if ([bb.instructions containsObject:incAdd])
                {
                incBlk = bb;
                break;
                }
        XTIRValue* newNext = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                           type:nt
                                                        defSite:[[XTIRDefSite alloc] initWithBlock:incBlk insnIndex:0]];
        [fn registerValue:newNext];

        // Narrow init constant, materialised in the preheader.
        XTIRValue* initC = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                         type:nt
                                                      defSite:[[XTIRDefSite alloc] initWithBlock:phBlk insnIndex:0]];
        [fn registerValue:initC];
        XTIRInsn* initI = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                    result:initC
                                                  operands:@[ [XTIROperand immIWithType:nt value:c0] ]
                                                    dbgLoc:nil];
        [phBlk.instructions addObject:initI];

        // Rebuilt phi / increment / guard.
        XTIRInsn* nPhi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                   result:newIV
                                                 operands:@[ [XTIROperand blockWithRef:phBlk], [XTIROperand useWithValueId:initC.valueId],
                                                             [XTIROperand blockWithRef:incBlk], [XTIROperand useWithValueId:newNext.valueId] ]
                                                   dbgLoc:nil];
        [H.phiNodes replaceObjectAtIndex:[H.phiNodes indexOfObjectIdenticalTo:ivPhi] withObject:nPhi];

        XTIRInsn* nAdd = [[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                   result:newNext
                                                 operands:@[ [XTIROperand useWithValueId:newIV.valueId], [XTIROperand immIWithType:nt value:step] ]
                                                   dbgLoc:nil];
        [incBlk.instructions replaceObjectAtIndex:[incBlk.instructions indexOfObjectIdenticalTo:incAdd] withObject:nAdd];

        XTIRInsn* nCmp = [[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                   result:cmp.result
                                                 operands:@[ [XTIROperand useWithValueId:newIV.valueId], [XTIROperand immIWithType:nt value:bound] ]
                                                predicate:(uint8_t)np
                                                   dbgLoc:nil];
        [H.instructions replaceObjectAtIndex:[H.instructions indexOfObjectIdenticalTo:cmp] withObject:nCmp];

        // Remap remaining direct uses (ElementAddr indices, ZExt/SExt) of the old
        // iv/next value-ids to the new narrow ones. The rebuilt phi/add/guard
        // already reference the new ids, so they are left untouched.
        for (XTIRBlock* bb in fn.blocks)
            {
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
            [all addObjectsFromArray:bb.instructions];
            if (bb.terminator)
                [all addObject:bb.terminator];
            for (XTIRInsn* insn in all)
                {
                BOOL changed = NO;
                NSMutableArray<XTIROperand*>* nops = [insn.operands mutableCopy];
                for (NSUInteger i = 0; i < nops.count; i++)
                    {
                    XTIROperand* o = nops[i];
                    if (o.kind != XTIROperandKindUse)
                        continue;
                    if (o.valueId == ivId)
                        {
                        nops[i] = [XTIROperand useWithValueId:newIV.valueId];
                        changed = YES;
                        }
                    else if (o.valueId == nextId)
                        {
                        nops[i] = [XTIROperand useWithValueId:newNext.valueId];
                        changed = YES;
                        }
                    }
                if (changed)
                    [insn replaceOperands:nops];
                }
            }
        return YES;
        }
    return NO;
    }

@end
