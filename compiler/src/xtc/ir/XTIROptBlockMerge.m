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

@implementation XTIROptConstBranches

- (NSString*)passName
    {
    return @"const-branches";
    }
- (NSInteger)minOptLevel
    {
    return 1;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    XTIROptBlockMerge* bm = [[XTIROptBlockMerge alloc] init];
    for (XTIRFunction* fn in mod.functions)
        while ([self foldOnce:fn])
            {
            [self dropUnreachable:fn];
            [bm pruneStaleIncomings:fn];
            }
    return YES;
    }

- (BOOL)foldOnce:(XTIRFunction*)fn
    {
    BOOL changed = NO;
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defs = nil;
    for (XTIRBlock* bb in fn.blocks)
        {
        XTIRInsn* t = bb.terminator;
        if (!t || t.opcode != XTIROpCondBranch || t.operands.count != 3)
            continue;
        XTIROperand* c = t.operands[0];
        int64_t k = -1;
        if (c.kind == XTIROperandKindImmI)
            k = c.intValue;
        else if (c.kind == XTIROperandKindUse)
            {
            if (!defs)
                {
                defs = [NSMutableDictionary dictionary];
                for (XTIRBlock* db in fn.blocks)
                    {
                    for (XTIRInsn* d in db.phiNodes)
                        if (d.result)
                            defs[@(d.result.valueId)] = d;
                    for (XTIRInsn* d in db.instructions)
                        if (d.result)
                            defs[@(d.result.valueId)] = d;
                    }
                }
            XTIRInsn* d = defs[@(c.valueId)];
            if (d && d.opcode == XTIROpConst && d.operands.count == 1 && d.operands[0].kind == XTIROperandKindImmI)
                k = d.operands[0].intValue;
            }
        if (k < 0)
            continue;
        XTIRInsn* br = [[XTIRInsn alloc] initWithOpcode:XTIROpBranch result:nil
                                               operands:@[ t.operands[k != 0 ? 1 : 2] ] dbgLoc:t.dbgLoc];
        [bb resetTerminator];
        [bb setTerminator:br];
        changed = YES;
        }
    return changed;
    }

// The blocks a path from the entry reaches, in the function's order.
- (void)dropUnreachable:(XTIRFunction*)fn
    {
    if (fn.blocks.count == 0)
        return;
    NSHashTable<XTIRBlock*>* seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSMutableArray<XTIRBlock*>* work = [NSMutableArray arrayWithObject:fn.blocks[0]];
    [seen addObject:fn.blocks[0]];
    while (work.count)
        {
        XTIRBlock* bb = work.lastObject;
        [work removeLastObject];
        for (XTIROperand* o in bb.terminator.operands)
            {
            if (o.kind != XTIROperandKindBlock || !o.blockRef || [seen containsObject:o.blockRef])
                continue;
            [seen addObject:o.blockRef];
            [work addObject:o.blockRef];
            }
        }
    // The memory tokens the dropped blocks made. Lowering does not merge
    // memory at a join (after `if (c) A else B` it carries on from B's), so a
    // kept block may name one: it takes the last token on its own path
    // instead (memBefore:).
    NSMutableSet<NSNumber*>* dead = [NSMutableSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        if ([seen containsObject:bb])
            continue;
        for (XTIRInsn* x in bb.phiNodes)
            if (x.memoryResult)
                [dead addObject:@(x.memoryResult.valueId)];
        for (XTIRInsn* x in bb.instructions)
            if (x.memoryResult)
                [dead addObject:@(x.memoryResult.valueId)];
        }
    for (NSUInteger k = fn.blocks.count; k > 1; k--)
        if (![seen containsObject:fn.blocks[k - 1]])
            [fn.blocks removeObjectAtIndex:k - 1];
    if (dead.count == 0)
        return;
    for (XTIRBlock* bb in fn.blocks)
        {
        XTIRValueId cur = 0;
        BOOL haveCur = NO;
        NSMutableArray<XTIRInsn*>* xs = [NSMutableArray arrayWithArray:bb.instructions];
        if (bb.terminator)
            [xs addObject:bb.terminator];
        for (XTIRInsn* x in xs)
            {
            NSMutableArray<XTIROperand*>* ops = [x.operands mutableCopy];
            BOOL hit = NO;
            for (NSUInteger q = 0; q < ops.count; q++)
                {
                if (ops[q].kind != XTIROperandKindUse || ![dead containsObject:@(ops[q].valueId)])
                    continue;
                ops[q] = [XTIROperand useWithValueId:haveCur ? cur : [self memBefore:bb in:fn depth:0]];
                hit = YES;
                }
            if (hit)
                [x replaceOperands:ops];
            if (x.memoryResult)
                {
                cur = x.memoryResult.valueId;
                haveCur = YES;
                }
            }
        }
    }

// The memory token in effect where block bb starts: the last one its one
// predecessor made (or had in effect), else the function's own.
- (XTIRValueId)memBefore:(XTIRBlock*)bb in:(XTIRFunction*)fn depth:(NSUInteger)depth
    {
    XTIRBlock* pred = nil;
    NSUInteger preds = 0;
    for (NSUInteger j = 0; j < fn.blocks.count && depth < 64; j++)
        {
        XTIRBlock* p = fn.blocks[j];
        for (XTIROperand* o in p.terminator.operands)
            if (o.kind == XTIROperandKindBlock && o.blockRef == bb)
                {
                if (pred != p)
                    preds++;
                pred = p;
                break;
                }
        }
    if (preds == 1)
        {
        for (NSUInteger i = pred.instructions.count; i > 0; i--)
            if (pred.instructions[i - 1].memoryResult)
                return pred.instructions[i - 1].memoryResult.valueId;
        for (XTIRInsn* x in pred.phiNodes)
            if (x.memoryResult)
                return x.memoryResult.valueId;
        return [self memBefore:pred in:fn depth:depth + 1];
        }
    return [fn valuesInPrintOrder][fn.paramTypes.count - 1].valueId;
    }

@end
