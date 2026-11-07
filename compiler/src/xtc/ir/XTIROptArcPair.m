#import "XTIROptArcPair.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRSupport.h"

@implementation XTIROptArcPair
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* _defs;
    NSMutableDictionary<NSNumber*, XTIRBlock*>* _phiBlock;
    XTIRBlock* _relBlock;
    }

- (NSString*)passName
    {
    return @"arc-pair";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

static BOOL apBlocks(XTIRInsn* n)
    {
    switch (n.opcode)
        {
    case XTIROpRetain:
        return NO;    // another count going up frees nothing
    case XTIROpStore:
    case XTIROpStoreVolatile:
    case XTIROpLoadVolatile:
    case XTIROpCall:
    case XTIROpCallIndirect:
    case XTIROpCallBanked:
    case XTIROpCallBankedIndirect:
    case XTIROpCallCloaked:
    case XTIROpMemSet:
    case XTIROpMemCopy:
    case XTIROpRelease:
    case XTIROpWeakRegister:
    case XTIROpWeakUnregister:
    case XTIROpVTblDispatch:
    case XTIROpProtoDispatch:
    case XTIROpAsm:
    case XTIROpReturn:
        return YES;
    default:
        return NO;
        }
    }

- (BOOL)sameObject:(XTIRValueId)v as:(XTIRValueId)x
    {
    for (int hop = 0; hop < 8; hop++)
        {
        if (v == x)
            return YES;
        XTIRInsn* d = _defs[@(v)];
        if (!d || d.opcode != XTIROpBitcast || d.operands.count < 1 || d.operands[0].kind != XTIROperandKindUse)
            return NO;
        v = d.operands[0].valueId;
        }
    return NO;
    }

- (BOOL)isNull:(XTIRValueId)v
    {
    XTIRInsn* d = _defs[@(v)];
    if (!d || d.opcode != XTIROpIntToPtr || d.operands.count < 1)
        return NO;
    XTIROperand* o = d.operands[0];
    if (o.kind == XTIROperandKindImmI)
        return o.intValue == 0;
    if (o.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* c = _defs[@(o.valueId)];
    return c && c.opcode == XTIROpConst && c.operands.count == 1 &&
           c.operands[0].kind == XTIROperandKindImmI && c.operands[0].intValue == 0;
    }

- (BOOL)nullEdgeFrom:(XTIRBlock*)p to:(XTIRBlock*)s value:(XTIRValueId)x
    {
    XTIRInsn* t = p.terminator;
    if (!t || t.opcode != XTIROpCondBranch || t.operands.count < 3)
        return NO;
    if (t.operands[1].blockRef != s || t.operands[2].blockRef == s)
        return NO;
    if (t.operands[0].kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* cmp = _defs[@(t.operands[0].valueId)];
    if (!cmp || cmp.opcode != XTIROpICmp || cmp.predicate != XTIRICmpEQ || cmp.operands.count < 2)
        return NO;
    XTIROperand *a = cmp.operands[0], *b = cmp.operands[1];
    if (a.kind != XTIROperandKindUse || b.kind != XTIROperandKindUse)
        return NO;
    return [self sameObject:a.valueId as:x] && [self isNull:b.valueId];
    }

- (BOOL)names:(XTIRValueId)v value:(XTIRValueId)x
    {
    if ([self sameObject:v as:x])
        return YES;
    XTIRInsn* d = _defs[@(v)];
    if (!d || d.opcode != XTIROpPhi)
        return NO;
    XTIRBlock* s = _phiBlock[@(v)];
    for (NSUInteger k = 0; k + 1 < d.operands.count; k += 2)
        {
        XTIRBlock* p = d.operands[k].blockRef;
        XTIROperand* o = d.operands[k + 1];
        if (o.kind != XTIROperandKindUse)
            return NO;
        if ([self sameObject:o.valueId as:x])
            continue;
        if ([self isNull:o.valueId] && s && [self nullEdgeFrom:p to:s value:x])
            continue;
        return NO;
        }
    return YES;
    }

- (nullable XTIRInsn*)findRelease:(XTIRBlock*)bb at:(NSUInteger)at value:(XTIRValueId)x
    {
    XTIRInsn* found = nil;
    NSMutableArray<XTIRBlock*>* work = [NSMutableArray arrayWithObject:bb];
    NSMutableArray<NSNumber*>* from = [NSMutableArray arrayWithObject:@(at + 1)];
    NSMutableArray<XTIRBlock*>* seen = [NSMutableArray array];
    while (work.count)
        {
        XTIRBlock* q = work.lastObject;
        NSUInteger start = from.lastObject.unsignedIntegerValue;
        [work removeLastObject];
        [from removeLastObject];
        BOOL stopped = NO;
        for (NSUInteger i = start; i < q.instructions.count; i++)
            {
            XTIRInsn* n = q.instructions[i];
            if (n.opcode == XTIROpRelease && n.operands.count >= 2 && n.operands[0].kind == XTIROperandKindUse &&
                [self names:n.operands[0].valueId value:x])
                {
                if (found && found != n)
                    return nil;
                found = n;
                _relBlock = q;
                stopped = YES;
                break;
                }
            if (apBlocks(n))
                return nil;
            }
        if (stopped)
            continue;
        XTIRInsn* t = q.terminator;
        if (!t)
            return nil;
        if (t.opcode == XTIROpUnreachable)
            continue;
        if (t.opcode != XTIROpBranch && t.opcode != XTIROpCondBranch)
            return nil;
        for (XTIROperand* o in t.operands)
            {
            if (o.kind != XTIROperandKindBlock || !o.blockRef)
                continue;
            XTIRBlock* s = o.blockRef;
            if (s == bb)
                return nil;
            if ([seen indexOfObjectIdenticalTo:s] != NSNotFound)
                continue;
            [seen addObject:s];
            [work addObject:s];
            [from addObject:@0];
            }
        }
    return found;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    for (XTIRFunction* fn in mod.functions)
        {
        _defs = [NSMutableDictionary dictionary];
        _phiBlock = [NSMutableDictionary dictionary];
        for (XTIRBlock* q in fn.blocks)
            {
            for (XTIRInsn* p in q.phiNodes)
                if (p.result)
                    {
                    _defs[@(p.result.valueId)] = p;
                    _phiBlock[@(p.result.valueId)] = q;
                    }
            for (XTIRInsn* n in q.instructions)
                if (n.result)
                    _defs[@(n.result.valueId)] = n;
            }
        NSMutableDictionary<NSNumber*, NSNumber*>* rename = [NSMutableDictionary dictionary];
        for (XTIRBlock* bb in fn.blocks)
            {
            NSUInteger i = 0;
            while (i < bb.instructions.count)
                {
                XTIRInsn* r = bb.instructions[i];
                if (r.opcode != XTIROpRetain || r.operands.count < 2 || r.operands[0].kind != XTIROperandKindUse ||
                    !r.memoryResult)
                    {
                    i++;
                    continue;
                    }
                XTIRInsn* rel = [self findRelease:bb at:i value:r.operands[0].valueId];
                if (!rel)
                    {
                    i++;
                    continue;
                    }
                rename[@(r.memoryResult.valueId)] = @(r.operands.lastObject.valueId);
                if (rel.memoryResult)
                    rename[@(rel.memoryResult.valueId)] = @(rel.operands.lastObject.valueId);
                [_relBlock.instructions removeObjectIdenticalTo:rel];
                [bb.instructions removeObjectAtIndex:i];
                }
            }
        if (!rename.count)
            continue;
        void (^renameIn)(XTIRInsn*) = ^(XTIRInsn* insn) {
            NSMutableArray<XTIROperand*>* ops = nil;
            for (NSUInteger k = 0; k < insn.operands.count; k++)
                {
                XTIROperand* o = insn.operands[k];
                if (o.kind != XTIROperandKindUse)
                    continue;
                XTIRValueId to = o.valueId;
                for (int hop = 0; hop < 64 && rename[@(to)]; hop++)
                    to = (XTIRValueId)rename[@(to)].unsignedLongLongValue;
                if (to == o.valueId)
                    continue;
                if (!ops)
                    ops = [insn.operands mutableCopy];
                ops[k] = [XTIROperand useWithValueId:to];
                }
            if (ops)
                [insn replaceOperands:ops];
        };
        for (XTIRBlock* bb in fn.blocks)
            {
            for (XTIRInsn* p in bb.phiNodes)
                renameIn(p);
            for (XTIRInsn* insn in bb.instructions)
                renameIn(insn);
            if (bb.terminator)
                renameIn(bb.terminator);
            }
        }
    return YES;
    }

@end
