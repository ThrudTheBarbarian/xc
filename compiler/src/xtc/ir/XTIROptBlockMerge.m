#import "XTIROptBlockMerge.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"

static NSArray<XTIRInsn*>* allInsns(XTIRBlock* b);

@implementation XTIROptBlockMerge

- (NSString*)passName
    {
    return @"block-merge";
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
        {
        [self pruneStaleIncomings:fn];
        while ([self mergeOne:fn])
            ;
        }
    return YES;
    }

// Drop every phi incoming whose block does not branch to the phi's block. A
// pass that deletes an edge without its incomings leaves them (the var-trip
// unroller's per-copy exits, once the trip is known to divide), and a stale
// incoming is not harmless: the allocator keeps its value live to the end of
// the named block, which in an unrolled loop is the whole body.
- (void)pruneStaleIncomings:(XTIRFunction*)fn
    {
    NSMapTable<XTIRBlock*, NSMutableSet<XTIRBlock*>*>* preds = [NSMapTable strongToStrongObjectsMapTable];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIROperand* o in bb.terminator.operands)
            if (o.kind == XTIROperandKindBlock && o.blockRef)
                {
                NSMutableSet<XTIRBlock*>* ps = [preds objectForKey:o.blockRef];
                if (!ps)
                    {
                    ps = [NSMutableSet set];
                    [preds setObject:ps forKey:o.blockRef];
                    }
                [ps addObject:bb];
                }
    for (XTIRBlock* S in fn.blocks)
        {
        NSSet<XTIRBlock*>* ps = [preds objectForKey:S];
        for (XTIRInsn* phi in S.phiNodes)
            {
            NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
            BOOL hit = NO;
            for (NSUInteger q = 0; q + 1 < phi.operands.count; q += 2)
                {
                if (![ps containsObject:phi.operands[q].blockRef])
                    {
                    hit = YES;
                    continue;
                    }
                [ops addObject:phi.operands[q]];
                [ops addObject:phi.operands[q + 1]];
                }
            if (hit && ops.count > 0)
                [phi replaceOperands:ops];
            }
        }
    // A block with ONE predecessor has phis of one incoming each, and each IS
    // its value. They are folded away: loop-rotate will not touch a loop whose
    // exit block already has phis, and the copy such a phi leaves in front of
    // an exit kept matrix_mul's inner loop top-tested.
    for (XTIRBlock* S in fn.blocks)
        {
        if (S == fn.blocks.firstObject || S.phiNodes.count == 0)
            continue;
        NSSet<XTIRBlock*>* ps = [preds objectForKey:S];
        if (ps.count != 1)
            continue;
        XTIRBlock* P = ps.anyObject;
        BOOL ok = YES;
        for (XTIRInsn* phi in S.phiNodes)
            if (phi.operands.count != 2 || phi.operands[0].blockRef != P || !phi.result || phi.memoryResult)
                ok = NO;
        if (!ok)
            continue;
        for (XTIRInsn* phi in S.phiNodes)
            {
            XTIRValueId from = phi.result.valueId;
            XTIROperand* to = phi.operands[1];
            for (XTIRBlock* bb in fn.blocks)
                for (XTIRInsn* i in allInsns(bb))
                    {
                    if (i == phi)
                        continue;
                    NSMutableArray<XTIROperand*>* ops = [i.operands mutableCopy];
                    BOOL hit = NO;
                    for (NSUInteger q = 0; q < ops.count; q++)
                        if (ops[q].kind == XTIROperandKindUse && ops[q].valueId == from)
                            {
                            ops[q] = to;
                            hit = YES;
                            }
                    if (hit)
                        [i replaceOperands:ops];
                    }
            }
        [S.phiNodes removeAllObjects];
        }
    }

// Every instruction of a block, phis and terminator included.
static NSArray<XTIRInsn*>* allInsns(XTIRBlock* b)
    {
    NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:b.phiNodes];
    [all addObjectsFromArray:b.instructions];
    if (b.terminator)
        [all addObject:b.terminator];
    return all;
    }

// Fold one block into its predecessor; NO when there is none to fold.
- (BOOL)mergeOne:(XTIRFunction*)fn
    {
    XTIRBlock* entry = fn.blocks.firstObject;
    // Every reference to a block from anywhere but a phi's incoming list is a
    // way into it (or something that names it). B may be folded only when the
    // branch from A is the one and only such reference.
    NSMapTable<XTIRBlock*, NSNumber*>* refs = [NSMapTable strongToStrongObjectsMapTable];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* insns = [NSMutableArray arrayWithArray:bb.instructions];
        if (bb.terminator)
            [insns addObject:bb.terminator];
        for (XTIRInsn* i in insns)
            for (XTIROperand* o in i.operands)
                if (o.kind == XTIROperandKindBlock && o.blockRef)
                    [refs setObject:@([[refs objectForKey:o.blockRef] integerValue] + 1) forKey:o.blockRef];
        }
    for (XTIRBlock* A in fn.blocks)
        {
        XTIRInsn* term = A.terminator;
        if (!term || term.opcode != XTIROpBranch || term.operands.count != 1)
            continue;
        XTIRBlock* B = term.operands[0].blockRef;
        if (!B || B == A || B == entry || [[refs objectForKey:B] integerValue] != 1)
            continue;
        // B's phis each have one incoming, from A: each IS that value.
        BOOL ok = YES;
        for (XTIRInsn* phi in B.phiNodes)
            if (phi.operands.count != 2 || phi.operands[0].blockRef != A || !phi.result)
                ok = NO;
        if (!ok)
            continue;
        for (XTIRInsn* phi in B.phiNodes)
            {
            XTIRValueId from = phi.result.valueId;
            XTIROperand* to = phi.operands[1];
            for (XTIRBlock* bb in fn.blocks)
                for (XTIRInsn* i in allInsns(bb))
                    {
                    if (i == phi)
                        continue;
                    NSMutableArray<XTIROperand*>* ops = [i.operands mutableCopy];
                    BOOL hit = NO;
                    for (NSUInteger q = 0; q < ops.count; q++)
                        if (ops[q].kind == XTIROperandKindUse && ops[q].valueId == from)
                            { ops[q] = to; hit = YES; }
                    if (hit)
                        [i replaceOperands:ops];
                    }
            }
        // B's real successors: the blocks its terminator names.
        NSMutableSet<XTIRBlock*>* succ = [NSMutableSet set];
        for (XTIROperand* o in B.terminator.operands)
            if (o.kind == XTIROperandKindBlock && o.blockRef)
                [succ addObject:o.blockRef];
        [A resetTerminator];
        [A.instructions addObjectsFromArray:B.instructions];
        if (B.terminator)
            [A setTerminator:B.terminator];
        // B's successors now have A where they had B. A phi anywhere else
        // that names B names a block that never branched to it: a stale entry,
        // left by a pass that deleted the edge but not the incoming (the
        // var-trip unroller's per-copy exits, once the trip count was known to
        // divide). It is dropped, not re-pointed: moved onto A it would keep
        // its value live across all of A, and in poly_dispatch's unrolled loop
        // that was three accumulators held across four calls, and two spills.
        for (XTIRBlock* S in fn.blocks)
            for (XTIRInsn* phi in S.phiNodes)
                {
                NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
                BOOL hit = NO;
                for (NSUInteger q = 0; q + 1 < phi.operands.count; q += 2)
                    {
                    XTIROperand* bo = phi.operands[q];
                    if (bo.blockRef != B)
                        {
                        [ops addObject:bo];
                        [ops addObject:phi.operands[q + 1]];
                        continue;
                        }
                    hit = YES;
                    if ([succ containsObject:S])
                        {
                        [ops addObject:[XTIROperand blockWithRef:A]];
                        [ops addObject:phi.operands[q + 1]];
                        }
                    }
                if (hit)
                    [phi replaceOperands:ops];
                }
        [fn.blocks removeObjectIdenticalTo:B];
        return YES;
        }
    return NO;
    }

@end
