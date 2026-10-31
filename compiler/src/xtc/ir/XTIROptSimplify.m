// XTIROptSimplify.m — see the header.
#import "XTIROptSimplify.h"
#include <float.h>
#include <math.h>
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
        [self strictFunction:fn];
        [self maskFunction:fn];
        [self balanceFunction:fn];
        }
    return YES;
    }

// `x <= K` for a constant K becomes `x < K + 1` where K + 1 fits (8 to 32
// bits): the loop passes read a bound with `<` (an inclusive range, `0...N -
// 1`, once folded, is `i <= 199999`; the vectoriser's constant-trip path took
// it as 199999 trips).
- (void)strictFunction:(XTIRFunction*)fn
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
    NSDictionary<NSNumber*, NSNumber*>* repl = @{};
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            {
            XTIRInsn* n = bb.instructions[i];
            if (n.opcode != XTIROpICmp || n.operands.count != 2)
                continue;
            BOOL ule = n.predicate == XTIRICmpULE, sle = n.predicate == XTIRICmpSLE;
            if (!ule && !sle)
                continue;
            XTIROperand* c = n.operands[1];
            XTIRType* t = c.kind == XTIROperandKindUse ? [fn valueForId:c.valueId].type : c.type;
            if (!t || !simpIntKind(t.kind) || t.byteWidth > 4)
                continue;
            BOOL unsignedTy = !simpSignedKind(t.kind);
            if (ule != unsignedTy)
                continue;
            int64_t k = 0;
            if (!simpConst(c, fn, defOf, repl, &k))
                continue;
            uint32_t bits = t.byteWidth * 8;
            int64_t kw, top;
            if (ule)
                {
                kw = k & (((int64_t)1 << bits) - 1);
                top = ((int64_t)1 << bits) - 1;
                }
            else
                {
                kw = simpWrap(k, t);
                top = ((int64_t)1 << (bits - 1)) - 1;
                }
            if (kw >= top)
                continue;
            XTIRValue* kv = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                          type:t
                                                       defSite:[[XTIRDefSite alloc] initWithBlock:bb insnIndex:i]];
            [fn registerValue:kv];
            XTIRInsn* kc = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                     result:kv
                                                   operands:@[ [XTIROperand immIWithType:t value:simpWrap(kw + 1, t)] ]
                                                     dbgLoc:n.dbgLoc];
            XTIRInsn* nc = [[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                     result:n.result
                                                   operands:@[ n.operands[0], [XTIROperand useWithValueId:kv.valueId] ]
                                                  predicate:(ule ? XTIRICmpULT : XTIRICmpSLT)
                                                     dbgLoc:n.dbgLoc];
            bb.instructions[i] = nc;
            [bb.instructions insertObject:kc atIndex:i];
            defOf[@(kv.valueId)] = kc;
            defOf[@(nc.result.valueId)] = nc;
            i++;
            }
        }
    }

// Masks: `(x & C1) & C2` is `x & (C1 & C2)`, and `(x & M) <u 2^k` is
// `(x & (M with the bits below 2^k cleared)) == 0` (`>=u`: `!= 0`), one bit
// test (8 to 32 bits). perlin's grad() reads `h & 7` as `g < 4`, `g & 1` and
// `g & 2`: they become h & 4, h & 1 and h & 2, and `h & 7` is dead.
- (void)maskFunction:(XTIRFunction*)fn
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
    NSDictionary<NSNumber*, NSNumber*>* repl = @{};
    for (XTIRBlock* bb in fn.blocks)
        {
        for (NSUInteger i = 0; i < bb.instructions.count; i++)
            {
            XTIRInsn* n = bb.instructions[i];
            BOOL band = n.opcode == XTIROpAnd;
            BOOL ult = n.opcode == XTIROpICmp && n.predicate == XTIRICmpULT;
            BOOL uge = n.opcode == XTIROpICmp && n.predicate == XTIRICmpUGE;
            if ((!band && !ult && !uge) || n.operands.count != 2)
                continue;
            XTIROperand* a = n.operands[0];
            if (a.kind != XTIROperandKindUse)
                continue;
            XTIRType* t = [fn valueForId:a.valueId].type;
            if (!t || !simpIntKind(t.kind) || t.byteWidth > 4)
                continue;
            int64_t k = 0;
            if (!simpConst(n.operands[1], fn, defOf, repl, &k))
                continue;
            XTIRInsn* d = defOf[@(a.valueId)];
            if (!d || d.opcode != XTIROpAnd || d.operands.count != 2 || d.operands[0].kind != XTIROperandKindUse)
                continue;
            int64_t m = 0;
            if (!simpConst(d.operands[1], fn, defOf, repl, &m))
                continue;
            XTIRValue* xv = [fn valueForId:d.operands[0].valueId];
            if (!xv || xv.type.kind != t.kind)
                continue;
            uint32_t bits = t.byteWidth * 8;
            int64_t wmask = ((int64_t)1 << bits) - 1;
            m &= wmask;
            k &= wmask;
            if (band)
                {
                [n replaceOperands:@[ [XTIROperand useWithValueId:xv.valueId],
                                      [XTIROperand immIWithType:t value:simpWrap(m & k, t)] ]];
                continue;
                }
            if (k == 0 || (k & (k - 1)) != 0)
                continue;
            int64_t mk = m & ~(k - 1);
            if (mk == 0)
                continue;
            XTIRValue* av = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                          type:t
                                                       defSite:[[XTIRDefSite alloc] initWithBlock:bb insnIndex:i]];
            [fn registerValue:av];
            XTIRInsn* na = [[XTIRInsn alloc] initWithOpcode:XTIROpAnd
                                                     result:av
                                                   operands:@[ [XTIROperand useWithValueId:xv.valueId],
                                                               [XTIROperand immIWithType:t value:simpWrap(mk, t)] ]
                                                     dbgLoc:n.dbgLoc];
            XTIRInsn* nc = [[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                     result:n.result
                                                   operands:@[ [XTIROperand useWithValueId:av.valueId],
                                                               [XTIROperand immIWithType:t value:0] ]
                                                  predicate:(ult ? XTIRICmpEQ : XTIRICmpNE)
                                                     dbgLoc:n.dbgLoc];
            bb.instructions[i] = nc;
            [bb.instructions insertObject:na atIndex:i];
            defOf[@(av.valueId)] = na;
            defOf[@(nc.result.valueId)] = nc;
            i++;
            }
        }
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

// A float operand's constant value, as the bits of a double: an immediate or
// a Const's, resolved through the replacements made so far.
static BOOL simpFConst(XTIROperand* o, NSDictionary<NSNumber*, XTIRInsn*>* defOf,
                       NSDictionary<NSNumber*, NSNumber*>* repl, double* out)
    {
    uint64_t bits = 0;
    if (o.kind == XTIROperandKindImmF)
        bits = o.floatRawBytes;
    else if (o.kind == XTIROperandKindUse)
        {
        XTIRInsn* d = defOf[@(simpResolve(repl, o.valueId))];
        if (!d || d.opcode != XTIROpConst || d.operands.count < 1 || d.operands[0].kind != XTIROperandKindImmF)
            return NO;
        bits = d.operands[0].floatRawBytes;
        }
    else
        return NO;
    memcpy(out, &bits, 8);
    return YES;
    }

// Floats of constants (2026-10-30): an int-to-float conversion of a constant
// of up to 32 bits, and FAdd/FSub/FMul/FDiv of two float constants, become a
// Const. Each is computed in the result's own precision, one IEEE rounding,
// which is what the hardware does at run time; a NaN or infinite result is
// left alone. mandel_deep's `(float)W` (W a u16 literal) stayed a UIToFp of a
// constant, and `1.5f / (float)W` a division on every item, which kept the
// escape vectoriser off its par body. nil when n is none of these.
static XTIRInsn* simpFoldFloat(XTIRInsn* n, XTIRFunction* fn, NSDictionary<NSNumber*, XTIRInsn*>* defOf,
                               NSDictionary<NSNumber*, NSNumber*>* repl)
    {
    XTIRValue* r = n.result;
    if (!r || n.memoryResult || (r.type.kind != XTIRTypeKindF32 && r.type.kind != XTIRTypeKindF64))
        return nil;
    BOOL f32 = r.type.kind == XTIRTypeKindF32;
    XTIROpcode op = n.opcode;
    double v = 0;
    if ((op == XTIROpUIToFp || op == XTIROpSIToFp) && n.operands.count == 1)
        {
        XTIROperand* a = n.operands[0];
        XTIRType* st = a.kind == XTIROperandKindUse ? [fn valueForId:a.valueId].type : a.type;
        int64_t k = 0;
        if (!st || !simpIntKind(st.kind) || st.byteWidth > 4 || !simpConst(a, fn, defOf, repl, &k))
            return nil;
        uint32_t sbits = st.byteWidth * 8;
        int64_t smask = ((int64_t)1 << sbits) - 1;
        int64_t u = k & smask;
        if (op == XTIROpSIToFp && u >= ((int64_t)1 << (sbits - 1)))
            u -= (int64_t)1 << sbits;
        if (f32)
            v = (double)(op == XTIROpUIToFp ? (float)(uint32_t)u : (float)(int32_t)u);
        else
            v = op == XTIROpUIToFp ? (double)(uint32_t)u : (double)(int32_t)u;
        }
    else if ((op == XTIROpFAdd || op == XTIROpFSub || op == XTIROpFMul || op == XTIROpFDiv) && n.operands.count == 2)
        {
        double x = 0, y = 0;
        if (!simpFConst(n.operands[0], defOf, repl, &x) || !simpFConst(n.operands[1], defOf, repl, &y))
            return nil;
        if (f32)
            {
            float fx = (float)x, fy = (float)y, fr;
            if (op == XTIROpFAdd) fr = fx + fy;
            else if (op == XTIROpFSub) fr = fx - fy;
            else if (op == XTIROpFMul) fr = fx * fy;
            else fr = fx / fy;
            // A subnormal float is left to the hardware (below).
            if (fr != 0.0f && fabsf(fr) < FLT_MIN)
                return nil;
            v = (double)fr;
            }
        else if (op == XTIROpFAdd) v = x + y;
        else if (op == XTIROpFSub) v = x - y;
        else if (op == XTIROpFMul) v = x * y;
        else v = x / y;
        }
    else
        return nil;
    // Not NaN or infinite, and not subnormal: a subnormal result is the
    // hardware's to make (a device that flushes subnormals to zero would not
    // make it), and the WAT printer spells one through the C library's %a,
    // which glibc and macOS write differently (math_lnexp_ieee, wasm).
    if (!isfinite(v) || (!f32 && v != 0.0 && fabs(v) < DBL_MIN))
        return nil;
    uint64_t bits = 0;
    memcpy(&bits, &v, 8);
    return [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                     result:r
                                   operands:@[ [XTIROperand immFWithType:r.type rawBytes:bits] ]
                                     dbgLoc:n.dbgLoc];
    }

// A multiply by a constant of a value plus constants, `(b + c) * k`, where
// another such product (or b * k itself) has the same b and k: each becomes
// `b * k + c * k`, so CSE leaves one multiply for the group. call_depth's
// inlined leaf(x), leaf(x + 1), leaf(x + 2), leaf(x + 3) multiplied four times
// where clang multiplies once, and a 32-bit vector multiply is one pipe at half
// rate on a Cortex-A76 (2026-10-31: Pi 1.26x clang). Wrapping arithmetic, so
// exact at every width up to 32 bits. The new multiply goes just before the
// one it replaces (b is defined before the chain that leads to it).
static BOOL simpPeel(XTIROperand* o, XTIRFunction* fn, NSDictionary<NSNumber*, XTIRInsn*>* defOf,
                     XTIRValueId* base, int64_t* sum)
    {
    if (o.kind != XTIROperandKindUse)
        return NO;
    XTIRValueId cur = o.valueId;
    int64_t c = 0;
    int steps = 0;
    NSDictionary<NSNumber*, NSNumber*>* none = @{};
    for (int i = 0; i < 8; i++)
        {
        XTIRInsn* d = defOf[@(cur)];
        if (!d || d.memoryResult || d.operands.count != 2 || (d.opcode != XTIROpAdd && d.opcode != XTIROpSub))
            break;
        int64_t k = 0;
        XTIROperand* x = d.operands[0];
        if (simpConst(d.operands[1], fn, defOf, none, &k) && x.kind == XTIROperandKindUse)
            c += d.opcode == XTIROpAdd ? k : -k;
        else if (d.opcode == XTIROpAdd && simpConst(x, fn, defOf, none, &k) && d.operands[1].kind == XTIROperandKindUse)
            {
            c += k;
            x = d.operands[1];
            }
        else
            break;
        cur = x.valueId;
        steps++;
        }
    *base = cur;
    *sum = c;
    return steps > 0;
    }

- (void)distributeMulsIn:(XTIRFunction*)fn
    {
    NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* i in bb.instructions)
            if (i.result)
                defOf[@(i.result.valueId)] = i;
    NSDictionary<NSNumber*, NSNumber*>* none = @{};
    // Each product by a constant: its base and constant sum, keyed by (base, k).
    NSMutableArray<XTIRInsn*>* cands = [NSMutableArray array];
    NSMutableArray<NSArray*>* info = [NSMutableArray array];
    NSCountedSet<NSString*>* group = [NSCountedSet set];
    for (XTIRBlock* bb in fn.blocks)
        for (XTIRInsn* n in bb.instructions)
            {
            XTIRValue* r = n.result;
            if (!r || n.memoryResult || n.opcode != XTIROpMul || n.operands.count != 2 || !simpIntKind(r.type.kind) ||
                r.type.byteWidth > 4)
                continue;
            int64_t k = 0;
            XTIROperand* v = nil;
            if (simpConst(n.operands[1], fn, defOf, none, &k))
                v = n.operands[0];
            else if (simpConst(n.operands[0], fn, defOf, none, &k))
                v = n.operands[1];
            if (!v || v.kind != XTIROperandKindUse)
                continue;
            XTIRValueId b = 0;
            int64_t c = 0;
            BOOL peeled = simpPeel(v, fn, defOf, &b, &c);
            XTIRValue* bv = [fn valueForId:b];
            if (!bv || bv.type.kind != r.type.kind)
                continue;
            NSString* key = [NSString stringWithFormat:@"%llu*%lld", (unsigned long long)b, (long long)simpWrap(k, r.type)];
            [group addObject:key];
            if (peeled)
                {
                [cands addObject:n];
                [info addObject:@[ @(b), @(k), @(c), key ]];
                }
            }
    // In block order: a product of b * k already made earlier in the block (one
    // the program wrote, or one made here) is reused, so a group leaves one
    // multiply whatever runs after (a vectorised copy is not CSE'd again).
    NSMapTable<XTIRInsn*, NSNumber*>* candAt = [NSMapTable strongToStrongObjectsMapTable];
    for (NSUInteger i = 0; i < cands.count; i++)
        [candAt setObject:@(i) forKey:cands[i]];
    for (XTIRBlock* bb in fn.blocks)
        {
        NSMutableDictionary<NSString*, NSNumber*>* avail = [NSMutableDictionary dictionary];
        for (NSUInteger at = 0; at < bb.instructions.count; at++)
            {
            XTIRInsn* n = bb.instructions[at];
            NSNumber* ci = [candAt objectForKey:n];
            if (!ci)
                {
                // A plain b * k (b not an add chain): available from here on.
                XTIRValue* r = n.result;
                if (r && !n.memoryResult && n.opcode == XTIROpMul && n.operands.count == 2 && simpIntKind(r.type.kind) &&
                    r.type.byteWidth <= 4)
                    {
                    int64_t k = 0;
                    XTIROperand* v = nil;
                    if (simpConst(n.operands[1], fn, defOf, none, &k))
                        v = n.operands[0];
                    else if (simpConst(n.operands[0], fn, defOf, none, &k))
                        v = n.operands[1];
                    if (v && v.kind == XTIROperandKindUse)
                        avail[[NSString stringWithFormat:@"%llu*%lld", (unsigned long long)v.valueId,
                                                         (long long)simpWrap(k, r.type)]] = @(r.valueId);
                    }
                continue;
                }
            NSUInteger i = ci.unsignedIntegerValue;
            NSString* key = info[i][3];
            if ([group countForObject:key] < 2)
                continue;
            XTIRValueId b = [info[i][0] unsignedLongLongValue];
            int64_t k = [info[i][1] longLongValue], c = [info[i][2] longLongValue];
            XTIRValue* r = n.result;
            XTIRValueId mid = 0;
            if (avail[key])
                mid = [avail[key] unsignedLongLongValue];
            else
                {
                mid = [fn allocateValueId];
                XTIRValue* mv = [[XTIRValue alloc] initWithValueId:mid
                                                              type:r.type
                                                           defSite:[[XTIRDefSite alloc] initWithBlock:bb insnIndex:at]];
                [fn registerValue:mv];
                XTIRInsn* m = [[XTIRInsn alloc] initWithOpcode:XTIROpMul
                                                        result:mv
                                                      operands:@[ [XTIROperand useWithValueId:b],
                                                                  [XTIROperand immIWithType:r.type value:simpWrap(k, r.type)] ]
                                                        dbgLoc:n.dbgLoc];
                [bb.instructions insertObject:m atIndex:at];
                at++;
                avail[key] = @(mid);
                }
            XTIRInsn* a = [[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                    result:r
                                                  operands:@[ [XTIROperand useWithValueId:mid],
                                                              [XTIROperand immIWithType:r.type value:simpWrap(c * k, r.type)] ]
                                                    dbgLoc:n.dbgLoc];
            bb.instructions[at] = a;
            }
        }
    }

- (void)runOnFunction:(XTIRFunction*)fn
    {
    if (fn.blocks.count == 0)
        return;
    [self distributeMulsIn:fn];
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
            XTIRInsn* fk = simpFoldFloat(n, fn, defOf, repl);
            if (fk)
                {
                bb.instructions[i] = fk;
                defOf[@(r.valueId)] = fk;
                continue;
                }
            // Neg of a constant (`-7`, which arrives as Neg #7), 8 to 32 bits.
            int64_t kn = 0;
            if (r && !n.memoryResult && n.opcode == XTIROpNeg && n.operands.count == 1 && simpIntKind(r.type.kind)
                && r.type.byteWidth <= 4 && simpConst(n.operands[0], fn, defOf, repl, &kn))
                {
                XTIRInsn* k = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                        result:r
                                                      operands:@[ [XTIROperand immIWithType:r.type
                                                                                      value:simpWrap(-simpWrap(kn, r.type), r.type)] ]
                                                        dbgLoc:n.dbgLoc];
                bb.instructions[i] = k;
                defOf[@(r.valueId)] = k;
                continue;
                }
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
