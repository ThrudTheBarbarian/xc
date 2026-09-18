#import "XTIROptJumpThread.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"

// The constant an operand resolves to, looking through the widening casts the
// front end puts on a boolean.
static BOOL constOf(XTIROperand* op, NSDictionary<NSNumber*, XTIRInsn*>* defOf, int64_t* out)
    {
    if (!op)
        return NO;
    if (op.kind == XTIROperandKindImmI)
        { *out = op.intValue; return YES; }
    if (op.kind != XTIROperandKindUse)
        return NO;
    XTIRValueId cur = op.valueId;
    for (int hop = 0; hop < 8; hop++)
        {
        XTIRInsn* d = defOf[@(cur)];
        if (!d || d.operands.count < 1)
            return NO;
        if (d.opcode == XTIROpConst && d.operands[0].kind == XTIROperandKindImmI)
            { *out = d.operands[0].intValue; return YES; }
        if (d.opcode != XTIROpZExt && d.opcode != XTIROpSExt && d.opcode != XTIROpTrunc)
            return NO;
        if (d.operands[0].kind != XTIROperandKindUse)
            return NO;
        cur = d.operands[0].valueId;
        }
    return NO;
    }

@implementation XTIROptJumpThread

- (NSString*)name
    {
    return @"jump-thread";
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
        for (int pass = 0; pass < 8 && [self runOnFunction:fn]; pass++)
            ;
    return YES;
    }

- (BOOL)runOnFunction:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (XTIRInsn* i in bb.phiNodes)
            if (i.result) defOf[@(i.result.valueId)] = i;
        for (XTIRInsn* i in bb.instructions)
            if (i.result) defOf[@(i.result.valueId)] = i;
        }

    for (XTIRBlock* J in fn.blocks)
        {
        // J must do NOTHING but merge and branch: a predecessor rewired past it
        // would skip any instruction it held.
        if (J.instructions.count != 0 || J.phiNodes.count != 1)
            continue;
        XTIRInsn* term = J.terminator;
        if (!term || term.opcode != XTIROpCondBranch || term.operands.count < 3)
            continue;
        if (term.operands[0].kind != XTIROperandKindUse)
            continue;
        XTIRInsn* phi = J.phiNodes[0];
        if (!phi.result || phi.result.valueId != term.operands[0].valueId)
            continue;
        if (phi.operands.count < 4)
            continue;                       // a 1-incoming phi has nothing to thread

        // The phi must be read by NOTHING but J's own branch. If anything else
        // reads it — a block J dominates, say — then a predecessor rewired past
        // J reaches that read with the phi never having executed, and it sees
        // whatever was in the register. That is the shape that segfaulted the
        // self-hosted compiler while all 19 benchmarks stayed correct: in
        // sort_small the phi feeds the branch and nothing else, so the missing
        // check cost nothing there.
        NSUInteger phiUses = 0;
        for (XTIRBlock* ub in fn.blocks)
            {
            NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
            [all addObjectsFromArray:ub.phiNodes];
            [all addObjectsFromArray:ub.instructions];
            if (ub.terminator) [all addObject:ub.terminator];
            for (XTIRInsn* ui in all)
                for (XTIROperand* uo in ui.operands)
                    if (uo.kind == XTIROperandKindUse && uo.valueId == phi.result.valueId)
                        phiUses++;
            }
        if (phiUses != 1)
            continue;

        // The phi's incoming list is NOT the authority on who reaches J — an
        // earlier pass can redirect an edge without touching the phi, and this
        // file's own loop transforms do exactly that. Count the real
        // predecessors from the terminators, and only proceed when the two
        // agree; otherwise collapsing the phi would assume a value that some
        // other path never supplies. Without this the pass miscompiled the
        // self-hosted compiler into an immediate segfault while all 19
        // benchmarks stayed correct.
        NSUInteger realPreds = 0;
        for (XTIRBlock* pb in fn.blocks)
            {
            if (!pb.terminator) continue;
            for (XTIROperand* o in pb.terminator.operands)
                if (o.kind == XTIROperandKindBlock && o.blockRef == J)
                    realPreds++;
            }
        if (realPreds != phi.operands.count / 2)
            continue;

        XTIRBlock* onTrue = term.operands[1].blockRef;
        XTIRBlock* onFalse = term.operands[2].blockRef;
        if (!onTrue || !onFalse)
            continue;
        // Redirecting an edge into a block with phis would need a new incoming
        // on each of them; keep to the case where there is nothing to add.
        if (onTrue.phiNodes.count || onFalse.phiNodes.count)
            continue;
        if (onTrue == J || onFalse == J)
            continue;   // a self-edge would drop an incoming it still needs

        for (NSUInteger k = 0; k + 1 < phi.operands.count; k += 2)
            {
            XTIRBlock* P = phi.operands[k].blockRef;
            int64_t kv;
            if (!P || P == J || !constOf(phi.operands[k + 1], defOf, &kv))
                continue;
            XTIRBlock* dest = kv ? onTrue : onFalse;
            XTIRInsn* pt = P.terminator;
            if (!pt)
                continue;
            // Rewrite P's every reference to J. A CondBranch with BOTH arms at
            // J would become a branch to dest either way, which is correct but
            // is left alone: it cannot arise from a short-circuit and is not
            // worth the extra case.
            NSMutableArray<XTIROperand*>* pops = [pt.operands mutableCopy];
            NSUInteger hits = 0;
            for (NSUInteger q = 0; q < pops.count; q++)
                if (pops[q].kind == XTIROperandKindBlock && pops[q].blockRef == J)
                    { pops[q] = [XTIROperand blockWithRef:dest]; hits++; }
            if (hits != 1)
                continue;
            [pt replaceOperands:pops];

            NSMutableArray<XTIROperand*>* keep = [NSMutableArray array];
            for (NSUInteger q = 0; q + 1 < phi.operands.count; q += 2)
                if (q != k)
                    { [keep addObject:phi.operands[q]]; [keep addObject:phi.operands[q + 1]]; }
            [phi replaceOperands:keep];

            // A phi with ONE incoming IS that incoming. Collapsing it is what
            // actually removes the boolean: left standing, it is a value the
            // allocator has to place, and when it misses it costs a store and a
            // reload on every iteration — which is the whole cost this pass
            // exists to remove.
            if (keep.count == 2 && keep[1].kind == XTIROperandKindUse && phi.result)
                {
                XTIRValueId from = phi.result.valueId, to = keep[1].valueId;
                for (XTIRBlock* bb in fn.blocks)
                    {
                    NSMutableArray<XTIRInsn*>* all = [NSMutableArray array];
                    [all addObjectsFromArray:bb.phiNodes];
                    [all addObjectsFromArray:bb.instructions];
                    if (bb.terminator) [all addObject:bb.terminator];
                    for (XTIRInsn* i in all)
                        {
                        NSMutableArray<XTIROperand*>* ops = [i.operands mutableCopy];
                        BOOL hit = NO;
                        for (NSUInteger q = 0; q < ops.count; q++)
                            if (ops[q].kind == XTIROperandKindUse && ops[q].valueId == from)
                                { ops[q] = [XTIROperand useWithValueId:to]; hit = YES; }
                        if (hit)
                            [i replaceOperands:ops];
                        }
                    }
                [J.phiNodes removeObjectIdenticalTo:phi];
                }
            return YES;                     // one edge per pass; defOf is stale now
            }
        }
    return NO;
    }

@end
