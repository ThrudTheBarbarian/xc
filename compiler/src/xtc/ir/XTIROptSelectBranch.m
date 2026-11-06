// XTIROptSelectBranch.m — a float Select whose arm computes becomes a branch
// (see the header). Every step and every block name as the port's
// selfhost/opt/OptSelectBranch.xc makes them.
#import "XTIROptSelectBranch.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIRValue.h"
#import "XTIRType.h"

// At most this many Selects become branches in one function (OptDefs.xc's SB_MAX).
#define SB_MAX 64

@implementation XTIROptSelectBranch
    {
    NSUInteger _seq;                    // the _sb<seq> in new block names
    XTIRFunction* _fn;
    NSMutableDictionary<NSNumber*, XTIRInsn*>* _defOf;
    }

- (NSString*)passName { return @"select-branch"; }
- (NSInteger)minOptLevel { return 2; }

- (BOOL)runOnModule:(XTIRModule*)mod errors:(NSMutableArray<NSString*>**)outErrors
    {
    (void)outErrors;
    if (!self.profile || !self.profile.selectsBranch)
        return YES;
    for (XTIRFunction* fn in mod.functions)
        {
        _fn = fn;
        NSUInteger guard = 0;
        while (guard < SB_MAX && [self one])
            guard++;
        }
    return YES;
    }

static BOOL sbFloat(XTIRValue* v)
    {
    return v && (v.type.kind == XTIRTypeKindF32 || v.type.kind == XTIRTypeKindF64);
    }

static BOOL sbArith(XTIROpcode op)
    {
    return op == XTIROpFAdd || op == XTIROpFSub || op == XTIROpFMul || op == XTIROpFNeg;
    }

// How many operands in the function read v.
- (NSUInteger)uses:(XTIRValueId)v
    {
    NSUInteger n = 0;
    for (XTIRBlock* bb in _fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* u in all)
            for (XTIROperand* o in u.operands)
                if (o.kind == XTIROperandKindUse && o.valueId == v)
                    n++;
        }
    return n;
    }

- (BOOL)constOf:(XTIROperand*)op value:(int64_t*)out
    {
    if (op.kind == XTIROperandKindImmI)
        {
        *out = op.intValue;
        return YES;
        }
    if (op.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* n = _defOf[@(op.valueId)];
    if (!n || n.operands.count < 1 || n.opcode != XTIROpConst || n.operands[0].kind != XTIROperandKindImmI)
        return NO;
    *out = n.operands[0].intValue;
    return YES;
    }

// The condition tests one bit: ICmp EQ/NE of (x & 2^k) against 0.
- (BOOL)bitTest:(XTIROperand*)c
    {
    if (c.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* cmp = _defOf[@(c.valueId)];
    if (!cmp || cmp.opcode != XTIROpICmp || cmp.operands.count != 2)
        return NO;
    if (cmp.predicate != XTIRICmpEQ && cmp.predicate != XTIRICmpNE)
        return NO;
    int64_t z = 1;
    if (![self constOf:cmp.operands[1] value:&z] || z != 0)
        return NO;
    XTIROperand* a = cmp.operands[0];
    if (a.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* an = _defOf[@(a.valueId)];
    if (!an || an.opcode != XTIROpAnd || an.operands.count != 2)
        return NO;
    int64_t k = 0;
    if (![self constOf:an.operands[1] value:&k] || k <= 0)
        return NO;
    return (k & (k - 1)) == 0;
    }

// Is block index bi inside a loop: a branch from a block at or after it back
// to one at or before it (the port's dvInLoop).
- (BOOL)inLoop:(NSUInteger)bi
    {
    NSArray<XTIRBlock*>* bs = _fn.blocks;
    for (NSUInteger u = bi; u < bs.count; u++)
        {
        XTIRInsn* t = bs[u].terminator;
        if (!t)
            continue;
        for (XTIROperand* o in t.operands)
            {
            if (o.kind != XTIROperandKindBlock || !o.blockRef)
                continue;
            for (NSUInteger h = 0; h <= bi; h++)
                if (bs[h] == o.blockRef)
                    return YES;
            }
        }
    return NO;
    }

static NSInteger indexIn(XTIRBlock* B, XTIRValueId v)
    {
    for (NSUInteger i = 0; i < B.instructions.count; i++)
        if (B.instructions[i].result && B.instructions[i].result.valueId == v)
            return (NSInteger)i;
    return -1;
    }

- (BOOL)one
    {
    _defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in _fn.blocks)
        {
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result)
                _defOf[@(p.result.valueId)] = p;
        for (XTIRInsn* n in bb.instructions)
            if (n.result)
                _defOf[@(n.result.valueId)] = n;
        }
    for (NSUInteger bi = 0; bi < _fn.blocks.count; bi++)
        {
        XTIRBlock* B = _fn.blocks[bi];
        if (![self inLoop:bi])
            continue;
        for (NSUInteger i = 0; i < B.instructions.count; i++)
            {
            XTIRInsn* n = B.instructions[i];
            if (n.opcode != XTIROpSelect || !n.result || n.operands.count != 3 || !sbFloat(n.result))
                continue;
            if (![self bitTest:n.operands[0]])
                continue;
            // The arm whose value only this Select reads and this block
            // computes, before it.
            NSUInteger arm = 0;
            NSInteger at = -1;
            for (NSUInteger k = 1; k <= 2 && arm == 0; k++)
                {
                XTIROperand* o = n.operands[k];
                if (o.kind != XTIROperandKindUse)
                    continue;
                NSInteger j = indexIn(B, o.valueId);
                if (j < 0 || (NSUInteger)j >= i || !sbArith(B.instructions[(NSUInteger)j].opcode))
                    continue;
                if ([self uses:o.valueId] != 1)
                    continue;
                arm = k;
                at = j;
                }
            if (arm == 0)
                continue;
            [self apply:bi index:i at:(NSUInteger)at arm:arm];
            return YES;
            }
        }
    return NO;
    }

static void retargetPhis(XTIRBlock* s, XTIRBlock* from, XTIRBlock* to)
    {
    for (XTIRInsn* ph in s.phiNodes)
        {
        NSMutableArray<XTIROperand*>* ops = nil;
        for (NSUInteger q = 0; q + 1 < ph.operands.count; q += 2)
            if (ph.operands[q].blockRef == from)
                {
                if (!ops)
                    ops = [ph.operands mutableCopy];
                ops[q] = [XTIROperand blockWithRef:to];
                }
        if (ops)
            [ph replaceOperands:ops];
        }
    }

// B: ... d (the arm's arithmetic) ... n = Select c, a, b ... rest
//  ->  B: ... CondBranch c, A|J, J|A
//      A: d; Branch J
//      J: n = Phi [(A, d), (B, the other)]; rest
- (void)apply:(NSUInteger)bi index:(NSUInteger)i at:(NSUInteger)at arm:(NSUInteger)arm
    {
    XTIRBlock* B = _fn.blocks[bi];
    XTIRInsn* n = B.instructions[i];
    XTIRInsn* d = B.instructions[at];
    _seq++;
    XTIRBlock* A = [[XTIRBlock alloc] init];
    A.name = [NSString stringWithFormat:@"%@_sb%lu_a", B.name ?: @"", (unsigned long)_seq];
    XTIRBlock* J = [[XTIRBlock alloc] init];
    J.name = [NSString stringWithFormat:@"%@_sb%lu_j", B.name ?: @"", (unsigned long)_seq];
    // J takes what follows the Select, and B's terminator.
    for (NSUInteger k = i + 1; k < B.instructions.count; k++)
        [J appendInstruction:B.instructions[k]];
    XTIRInsn* bt = B.terminator;
    if (bt)
        {
        [B resetTerminator];
        [J setTerminator:bt];
        for (XTIROperand* o in bt.operands)
            if (o.kind == XTIROperandKindBlock && o.blockRef)
                retargetPhis(o.blockRef, B, J);
        }
    // A computes the arm.
    [A appendInstruction:d];
    [A setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpBranch
                                               result:nil
                                             operands:@[ [XTIROperand blockWithRef:J] ]
                                               dbgLoc:nil]];
    // B keeps what came before, less the arm.
    NSMutableArray<XTIRInsn*>* keep = [NSMutableArray array];
    for (NSUInteger k = 0; k < i; k++)
        if (k != at)
            [keep addObject:B.instructions[k]];
    [B.instructions removeAllObjects];
    for (XTIRInsn* k in keep)
        [B appendInstruction:k];
    [B setTerminator:[[XTIRInsn alloc] initWithOpcode:XTIROpCondBranch
                                               result:nil
                                             operands:@[ n.operands[0],
                                                         [XTIROperand blockWithRef:(arm == 1 ? A : J)],
                                                         [XTIROperand blockWithRef:(arm == 1 ? J : A)] ]
                                               dbgLoc:nil]];
    // J's phi is the Select's result.
    XTIRInsn* ph = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                             result:n.result
                                           operands:@[ [XTIROperand blockWithRef:A], n.operands[arm],
                                                       [XTIROperand blockWithRef:B], n.operands[arm == 1 ? 2 : 1] ]
                                             dbgLoc:nil];
    [J.phiNodes addObject:ph];
    NSMutableArray<XTIRBlock*>* blocks = [NSMutableArray array];
    for (NSUInteger b = 0; b < _fn.blocks.count; b++)
        {
        [blocks addObject:_fn.blocks[b]];
        if (b == bi)
            {
            [blocks addObject:A];
            [blocks addObject:J];
            }
        }
    [_fn.blocks setArray:blocks];
    }

@end
