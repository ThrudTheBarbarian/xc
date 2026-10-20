// XTIROptSimplify.m — see the header.
#import "XTIROptSimplify.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"

static BOOL simpIntKind(XTIRTypeKind k)
    {
    return k == XTIRTypeKindI8 || k == XTIRTypeKindU8 || k == XTIRTypeKindI16 || k == XTIRTypeKindU16 ||
           k == XTIRTypeKindI32 || k == XTIRTypeKindU32 || k == XTIRTypeKindI64 || k == XTIRTypeKindU64;
    }

static BOOL simpSignedKind(XTIRTypeKind k)
    {
    return k == XTIRTypeKindI8 || k == XTIRTypeKindI16 || k == XTIRTypeKindI32 || k == XTIRTypeKindI64;
    }

// v wrapped to t's width (8 to 32 bits).
static int64_t simpWrap(int64_t v, XTIRType* t)
    {
    uint32_t bits = t.byteWidth * 8;
    int64_t span = (int64_t)1 << bits;
    int64_t r = v & (span - 1);
    if (simpSignedKind(t.kind) && r >= span / 2)
        r -= span;
    return r;
    }

@implementation XTIROptSimplify

- (NSString*)passName
    {
    return @"simplify";
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
        [self runOnFunction:fn];
        [self balanceFunction:fn];
        }
    return YES;
    }

static BOOL simpAssoc(XTIROpcode op)
    {
    return op == XTIROpAdd || op == XTIROpXor || op == XTIROpAnd || op == XTIROpOr;
    }

static uint32_t simpDepthOf(XTIROperand* o, NSDictionary<NSNumber*, NSNumber*>* depth, NSSet<NSNumber*>* phiIds)
    {
    if (o.kind != XTIROperandKindUse)
        return 0;
    if ([phiIds containsObject:@(o.valueId)])
        return 1048576;
    NSNumber* d = depth[@(o.valueId)];
    return d ? (uint32_t)d.unsignedIntValue : 0;
    }

// The leaves of the tree under n, left first, and its interior nodes.
static void simpLeaves(XTIRInsn* n, NSDictionary<NSNumber*, XTIRInsn*>* defIn, NSCountedSet<NSNumber*>* uses,
                       NSMutableArray<XTIROperand*>* leaves, NSMutableArray<XTIRInsn*>* inner)
    {
    for (NSUInteger k = 0; k < 2; k++)
        {
        XTIROperand* o = n.operands[k];
        XTIRInsn* d = o.kind == XTIROperandKindUse ? defIn[@(o.valueId)] : nil;
        if (d && d.opcode == n.opcode && !d.memoryResult && d.operands.count == 2 && d.result.type &&
            d.result.type.kind == n.result.type.kind && [uses countForObject:@(d.result.valueId)] == 1)
            {
            simpLeaves(d, defIn, uses, leaves, inner);
            [inner addObject:d];
            }
        else
            [leaves addObject:o];
        }
    }

- (void)balanceFunction:(XTIRFunction*)fn
    {
    NSCountedSet<NSNumber*>* uses = [NSCountedSet set];
    NSMutableSet<NSNumber*>* phiIds = [NSMutableSet set];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableArray<XTIRInsn*>* all = [NSMutableArray arrayWithArray:bb.phiNodes];
        [all addObjectsFromArray:bb.instructions];
        if (bb.terminator)
            [all addObject:bb.terminator];
        for (XTIRInsn* i in all)
            for (XTIROperand* o in i.operands)
                if (o.kind == XTIROperandKindUse)
                    [uses addObject:@(o.valueId)];
        for (XTIRInsn* p in bb.phiNodes)
            if (p.result)
                [phiIds addObject:@(p.result.valueId)];
        }
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableDictionary<NSNumber*, XTIRInsn*>* defIn = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSNumber*, NSNumber*>* depth = [NSMutableDictionary dictionary];
        // Which block value a single-use value feeds, to find the roots.
        NSMutableDictionary<NSNumber*, XTIRInsn*>* userOf = [NSMutableDictionary dictionary];
        for (XTIRInsn* n in bb.instructions)
            for (XTIROperand* o in n.operands)
                if (o.kind == XTIROperandKindUse)
                    userOf[@(o.valueId)] = n;
        NSMutableArray<XTIRInsn*>* out = [NSMutableArray array];
        BOOL changed = NO;
        for (XTIRInsn* n in [bb.instructions copy])
            {
            XTIRValue* r = n.result;
            uint32_t dn = 0;
            if (n.opcode != XTIROpConst)
                for (XTIROperand* o in n.operands)
                    {
                    uint32_t dk = simpDepthOf(o, depth, phiIds) + 1;
                    if (dk > dn)
                        dn = dk;
                    }
            BOOL tree = r && !n.memoryResult && n.operands.count == 2 && simpAssoc(n.opcode) &&
                        simpIntKind(r.type.kind);
            if (tree)
                {
                // A root: not the one use of a like node in this block.
                XTIRInsn* u = userOf[@(r.valueId)];
                if ([uses countForObject:@(r.valueId)] == 1 && u && u.opcode == n.opcode && !u.memoryResult &&
                    u.result && u.result.type && u.result.type.kind == r.type.kind)
                    tree = NO;
                }
            NSMutableArray<XTIROperand*>* leaves = [NSMutableArray array];
            NSMutableArray<XTIRInsn*>* inner = [NSMutableArray array];
            if (tree)
                {
                simpLeaves(n, defIn, uses, leaves, inner);
                tree = leaves.count >= 3;
                }
            if (!tree)
                {
                [out addObject:n];
                if (r)
                    {
                    defIn[@(r.valueId)] = n;
                    depth[@(r.valueId)] = @(dn);
                    }
                continue;
                }
            // Shallowest two first (the earlier on a tie), until one is left:
            // its depth against the tree's now.
            NSMutableArray<XTIROperand*>* items = [NSMutableArray array];
            NSMutableArray<NSNumber*>* idep = [NSMutableArray array];
            for (XTIROperand* l in leaves)
                {
                [items addObject:l];
                [idep addObject:@(simpDepthOf(l, depth, phiIds))];
                }
            NSMutableArray<XTIRInsn*>* built = [NSMutableArray array];
            while (items.count > 1)
                {
                NSUInteger p0 = 0;
                for (NSUInteger k = 1; k < items.count; k++)
                    if (idep[k].unsignedIntValue < idep[p0].unsignedIntValue)
                        p0 = k;
                XTIROperand* x = items[p0];
                uint32_t dx = idep[p0].unsignedIntValue;
                [items removeObjectAtIndex:p0];
                [idep removeObjectAtIndex:p0];
                NSUInteger p1 = 0;
                for (NSUInteger k = 1; k < items.count; k++)
                    if (idep[k].unsignedIntValue < idep[p1].unsignedIntValue)
                        p1 = k;
                XTIROperand* y = items[p1];
                uint32_t dy = idep[p1].unsignedIntValue;
                [items removeObjectAtIndex:p1];
                [idep removeObjectAtIndex:p1];
                XTIRValue* nv = built.count < inner.count ? inner[built.count].result : r;
                XTIRInsn* c = [[XTIRInsn alloc] initWithOpcode:n.opcode result:nv operands:@[ x, y ] dbgLoc:n.dbgLoc];
                [built addObject:c];
                [items addObject:[XTIROperand useWithValueId:nv.valueId]];
                [idep addObject:@((dx > dy ? dx : dy) + 1)];
                }
            uint32_t dnew = idep[0].unsignedIntValue;
            if (dnew >= dn)
                {
                [out addObject:n];
                defIn[@(r.valueId)] = n;
                depth[@(r.valueId)] = @(dn);
                continue;
                }
            // The interior nodes leave their places; the rebuilt tree stands
            // at the root's.
            for (XTIRInsn* d in inner)
                {
                NSUInteger q = [out indexOfObjectIdenticalTo:d];
                if (q != NSNotFound)
                    [out removeObjectAtIndex:q];
                }
            for (XTIRInsn* c in built)
                {
                uint32_t dc = 0;
                for (XTIROperand* o in c.operands)
                    {
                    uint32_t dq = simpDepthOf(o, depth, phiIds) + 1;
                    if (dq > dc)
                        dc = dq;
                    }
                [out addObject:c];
                defIn[@(c.result.valueId)] = c;
                depth[@(c.result.valueId)] = @(dc);
                }
            changed = YES;
            }
        if (changed)
            [bb.instructions setArray:out];
        }
    }

static XTIRValueId simpResolve(NSDictionary<NSNumber*, NSNumber*>* repl, XTIRValueId v)
    {
    XTIRValueId cur = v;
    for (int i = 0; i < 64; i++)
        {
        NSNumber* nx = repl[@(cur)];
        if (!nx || nx.unsignedLongLongValue == cur)
            return cur;
        cur = (XTIRValueId)nx.unsignedLongLongValue;
        }
    return cur;
    }

// An operand's constant value (an immediate, a Const's, or an extension of
// one), resolved through the replacements made so far.
static BOOL simpConst(XTIROperand* o, XTIRFunction* fn, NSDictionary<NSNumber*, XTIRInsn*>* defOf,
                      NSDictionary<NSNumber*, NSNumber*>* repl, int64_t* out)
    {
    if (o.kind == XTIROperandKindImmI)
        {
        *out = o.intValue;
        return YES;
        }
    if (o.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* d = defOf[@(simpResolve(repl, o.valueId))];
    if (!d || d.operands.count < 1)
        return NO;
    XTIROperand* d0 = d.operands[0];
    if (d.opcode == XTIROpConst)
        {
        if (d0.kind != XTIROperandKindImmI)
            return NO;
        *out = d0.intValue;
        return YES;
        }
    BOOL zx = d.opcode == XTIROpZExt, sx = d.opcode == XTIROpSExt, tr = d.opcode == XTIROpTrunc;
    if (!zx && !sx && !tr)
        return NO;
    XTIRType* st = d0.kind == XTIROperandKindUse ? [fn valueForId:d0.valueId].type : d0.type;
    if (!st || !simpIntKind(st.kind) || st.byteWidth > 4)
        return NO;
    int64_t k = 0;
    if (!simpConst(d0, fn, defOf, repl, &k))
        return NO;
    uint32_t sbits = st.byteWidth * 8;
    int64_t smask = ((int64_t)1 << sbits) - 1;
    if (zx)
        *out = k & smask;
    else if (sx)
        {
        int64_t u = k & smask;
        *out = u >= ((int64_t)1 << (sbits - 1)) ? u - ((int64_t)1 << sbits) : u;
        }
    else
        *out = k;
    return YES;
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    if (fn.blocks.count == 0)
        return;
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
    NSMutableDictionary<NSNumber*, NSNumber*>* repl = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            {
            XTIRInsn* n = bb.instructions[i];
            XTIRValue* r = n.result;
            if (!r || n.memoryResult || n.operands.count != 2 || !simpIntKind(r.type.kind))
                continue;
            XTIROpcode op = n.opcode;
            BOOL add = op == XTIROpAdd, sub = op == XTIROpSub, mul = op == XTIROpMul, band = op == XTIROpAnd,
                 bor = op == XTIROpOr, bxor = op == XTIROpXor, shl = op == XTIROpShl,
                 lshr = op == XTIROpLShr, ashr = op == XTIROpAShr;
            if (!add && !sub && !mul && !band && !bor && !bxor && !shl && !lshr && !ashr)
                continue;
            XTIROperand* a = n.operands[0];
            XTIROperand* c = n.operands[1];
            int64_t ka = 0, kc = 0;
            BOOL ca = simpConst(a, fn, defOf, repl, &ka);
            BOOL cc = simpConst(c, fn, defOf, repl, &kc);
            uint32_t w = r.type.byteWidth;
            BOOL small = w <= 4;
            if (ca && cc && small)
                {
                uint32_t bits = w * 8;
                int64_t x = simpWrap(ka, r.type), y = simpWrap(kc, r.type);
                int64_t mask = ((int64_t)1 << bits) - 1;
                BOOL ok = YES;
                int64_t v = 0;
                if (add) v = x + y;
                else if (sub) v = x - y;
                else if (mul) v = x * y;
                else if (band) v = x & y;
                else if (bor) v = x | y;
                else if (bxor) v = x ^ y;
                else
                    {
                    int64_t sh = y & mask;
                    if (sh < 0 || sh >= (int64_t)bits)
                        ok = NO;
                    else if (shl) v = x << sh;
                    else if (lshr) v = (x & mask) >> sh;
                    else v = x >> sh;
                    }
                if (ok)
                    {
                    XTIRInsn* k = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                            result:r
                                                          operands:@[ [XTIROperand immIWithType:r.type
                                                                                          value:simpWrap(v, r.type)] ]
                                                            dbgLoc:n.dbgLoc];
                    bb.instructions[i] = k;
                    defOf[@(r.valueId)] = k;
                    }
                continue;
                }
            // The identities: the other operand must be a value (an immediate
            // pair was folded above, or is 64-bit).
            int64_t ones = small ? simpWrap(-1, r.type) : -1;
            XTIROperand* keep = nil;
            BOOL zero = NO;
            if (cc)
                {
                int64_t y = small ? simpWrap(kc, r.type) : kc;
                if ((add || sub || bor || bxor || shl || lshr || ashr) && y == 0) keep = a;
                else if (mul && y == 1) keep = a;
                else if (band && y == ones) keep = a;
                else if ((mul || band) && y == 0) zero = YES;
                }
            else if (ca)
                {
                int64_t x = small ? simpWrap(ka, r.type) : ka;
                if ((add || bor || bxor) && x == 0) keep = c;
                else if (mul && x == 1) keep = c;
                else if (band && x == ones) keep = c;
                else if ((mul || band) && x == 0) zero = YES;
                }
            if (zero)
                {
                XTIRInsn* k = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                        result:r
                                                      operands:@[ [XTIROperand immIWithType:r.type value:0] ]
                                                        dbgLoc:n.dbgLoc];
                bb.instructions[i] = k;
                defOf[@(r.valueId)] = k;
                continue;
                }
            if (keep && keep.kind == XTIROperandKindUse)
                {
                XTIRValue* kv = [fn valueForId:keep.valueId];
                if (kv && kv.type.kind == r.type.kind)
                    repl[@(r.valueId)] = @(simpResolve(repl, keep.valueId));
                }
            }
        }
    if (repl.count == 0)
        return;
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
                XTIROperand* o = ops[k];
                if (o.kind != XTIROperandKindUse)
                    continue;
                XTIRValueId to = simpResolve(repl, o.valueId);
                if (to == o.valueId)
                    continue;
                ops[k] = [XTIROperand useWithValueId:to];
                changed = YES;
                }
            if (changed)
                [insn replaceOperands:ops];
            }
        }
    }

@end
