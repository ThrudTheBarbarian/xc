#import "XTIROptBoundsElide.h"
#import "XTIROptIfConvert.h"
#import "XTIROptDeadCode.h"
#import "XTIROptRedundantLoadCSE.h"
#import "XTIROptTargetProfile.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRSymbol.h"
#import "XTIRSupport.h"
#import "XTIRType.h"

// A compile-time integer through Const and the width casts (as the
// vectoriser's constant reader).
static BOOL constWide(XTIROperand* op, NSDictionary<NSNumber*, XTIRInsn*>* defOf, int64_t* out)
    {
    if (op.kind == XTIROperandKindImmI)
        {
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
        XTIROperand* a = def.operands[0];
        if (def.opcode == XTIROpConst)
            {
            if (a.kind != XTIROperandKindImmI)
                return NO;
            *out = a.intValue;
            return YES;
            }
        if (def.opcode != XTIROpZExt && def.opcode != XTIROpSExt && def.opcode != XTIROpTrunc)
            return NO;
        if (a.kind == XTIROperandKindImmI)
            {
            *out = a.intValue;
            return YES;
            }
        if (a.kind != XTIROperandKindUse)
            return NO;
        cur = a.valueId;
        }
    return NO;
    }

// What a guard's edge says of one value, as a closed range.
@interface XTBeFact : NSObject
@property(nonatomic) XTIRValueId v;
@property(nonatomic) int64_t lo;
@property(nonatomic) int64_t hi;
@end
@implementation XTBeFact
@end

// The whole range of a value's type; NO for anything but an integer. U64's top
// half is left out, so every bound fits an int64_t with room to add.
static BOOL typeRange(XTIRType* ty, int64_t* lo, int64_t* hi)
    {
    int w = 0;
    BOOL sgn = NO;
    switch (ty.kind)
        {
        case XTIRTypeKindU8: w = 8; break;
        case XTIRTypeKindU16: w = 16; break;
        case XTIRTypeKindU32: w = 32; break;
        case XTIRTypeKindU64: w = 62; break;
        case XTIRTypeKindI8: w = 8; sgn = YES; break;
        case XTIRTypeKindI16: w = 16; sgn = YES; break;
        case XTIRTypeKindI32: w = 32; sgn = YES; break;
        case XTIRTypeKindI64: w = 62; sgn = YES; break;
        default: return NO;
        }
    if (sgn)
        {
        *lo = -((int64_t)1 << (w - 1));
        *hi = ((int64_t)1 << (w - 1)) - 1;
        }
    else
        {
        *lo = 0;
        *hi = ((int64_t)1 << w) - 1;
        }
    return YES;
    }

static BOOL isUnsignedKind(XTIRType* ty)
    {
    return ty.kind == XTIRTypeKindU8 || ty.kind == XTIRTypeKindU16 || ty.kind == XTIRTypeKindU32 || ty.kind == XTIRTypeKindU64;
    }

static BOOL isCall(XTIRInsn* n, XTIRSymbolId sid, NSUInteger nops)
    {
    return n.opcode == XTIROpCall && n.operands.count == nops && n.operands[0].kind == XTIROperandKindSym &&
           n.operands[0].symbolId == sid;
    }

static void replaceUses(XTIRInsn* insn, XTIRValueId old, XTIROperand* to)
    {
    BOOL hit = NO;
    for (XTIROperand* o in insn.operands)
        if (o.kind == XTIROperandKindUse && o.valueId == old)
            hit = YES;
    if (!hit)
        return;
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray arrayWithCapacity:insn.operands.count];
    for (XTIROperand* o in insn.operands)
        [ops addObject:(o.kind == XTIROperandKindUse && o.valueId == old) ? to : o];
    [insn replaceOperands:ops];
    }

@interface XTIROptBoundsElide ()
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf;
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, XTIRValue*>* valueOf;
@property(nonatomic, strong) NSMutableSet<NSNumber*>* visiting;
@property(nonatomic, strong) NSMutableArray<XTBeFact*>* facts;
@property(nonatomic, strong) XTIRModule* mod;
@end

@implementation XTIROptBoundsElide

- (NSString*)passName
    {
    return @"bounds-elide";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

// `ElementAddr base, ZExt(x)` with x a 32-bit integer: x (as a use), else nil.
- (nullable XTIROperand*)wideIndexOf:(XTIRInsn*)n
    {
    if (n.opcode != XTIROpElementAddr || n.operands.count < 2 || !self.defOf)
        return nil;
    XTIROperand* ix = n.operands[1];
    if (ix.kind != XTIROperandKindUse)
        return nil;
    XTIRInsn* d = self.defOf[@(ix.valueId)];
    if (!d || d.opcode != XTIROpZExt || d.operands.count < 1)
        return nil;
    XTIROperand* a = d.operands[0];
    if (a.kind != XTIROperandKindUse)
        return nil;
    XTIRValue* v = self.valueOf[@(a.valueId)];
    if (!v || !(v.type.kind == XTIRTypeKindI32 || v.type.kind == XTIRTypeKindU32))
        return nil;
    return [XTIROperand useWithValueId:a.valueId];
    }

// The element count of the `new T[c]` that made p, c a constant: p is the
// result of a call to an `_xtc_new_<T>` allocator, whose one argument is the
// count.
- (BOOL)newCount:(XTIROperand*)p count:(int64_t*)count
    {
    if (p.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* d = self.defOf[@(p.valueId)];
    if (!d || d.opcode != XTIROpCall || d.operands.count != 3 || d.operands[0].kind != XTIROperandKindSym)
        return NO;
    XTIRSymbol* s = [self.mod symbolForId:d.operands[0].symbolId];
    if (![s.name hasPrefix:@"_xtc_new_"])
        return NO;
    return constWide(d.operands[1], self.defOf, count) && *count > 0;
    }

- (BOOL)range:(XTIROperand*)op lo:(int64_t*)lo hi:(int64_t*)hi depth:(int)depth
    {
    if (op.kind == XTIROperandKindImmI)
        {
        *lo = *hi = op.intValue;
        return YES;
        }
    if (op.kind != XTIROperandKindUse || depth > 24)
        return NO;
    XTIRValue* v = self.valueOf[@(op.valueId)];
    int64_t tlo = 0, thi = 0;
    if (!v || !typeRange(v.type, &tlo, &thi))
        return NO;
    int64_t rlo = tlo, rhi = thi;
    XTIRInsn* def = self.defOf[@(op.valueId)];
    if (def)
        {
        int64_t dlo = 0, dhi = 0;
        if ([self defRange:def value:op.valueId lo:&dlo hi:&dhi depth:depth] && dlo >= tlo && dhi <= thi)
            {
            rlo = dlo;
            rhi = dhi;
            }
        }
    for (XTBeFact* f in self.facts)
        {
        if (f.v != op.valueId)
            continue;
        if (f.lo > rlo)
            rlo = f.lo;
        if (f.hi < rhi)
            rhi = f.hi;
        }
    *lo = rlo;
    *hi = rhi;
    return rlo <= rhi;
    }

- (BOOL)defRange:(XTIRInsn*)def value:(XTIRValueId)v lo:(int64_t*)lo hi:(int64_t*)hi depth:(int)depth
    {
    NSArray<XTIROperand*>* ops = def.operands;
    int64_t alo = 0, ahi = 0, blo = 0, bhi = 0;
    int64_t big = (int64_t)1 << 61;
    if (def.opcode == XTIROpConst)
        {
        if (ops.count < 1 || ops[0].kind != XTIROperandKindImmI)
            return NO;
        *lo = *hi = ops[0].intValue;
        return YES;
        }
    if (def.opcode == XTIROpPhi)
        return [self phiRange:def value:v lo:lo hi:hi depth:depth];
    if (ops.count < 1 || ![self range:ops[0] lo:&alo hi:&ahi depth:depth + 1])
        return NO;
    if (def.opcode == XTIROpZExt)
        {
        if (alo < 0)
            return NO;
        *lo = alo;
        *hi = ahi;
        return YES;
        }
    if (def.opcode == XTIROpSExt || def.opcode == XTIROpTrunc)
        {
        *lo = alo;
        *hi = ahi;
        return YES;
        }
    if (ops.count < 2 || ![self range:ops[1] lo:&blo hi:&bhi depth:depth + 1])
        return NO;
    if (alo < -big || ahi > big || blo < -big || bhi > big)
        return NO;
    int64_t lim = (int64_t)1 << 30;
    switch (def.opcode)
        {
        case XTIROpAdd:
            *lo = alo + blo;
            *hi = ahi + bhi;
            return YES;
        case XTIROpSub:
            *lo = alo - bhi;
            *hi = ahi - blo;
            return YES;
        case XTIROpMul:
            if (alo < 0 || blo < 0 || ahi > lim || bhi > lim)
                return NO;
            *lo = alo * blo;
            *hi = ahi * bhi;
            return YES;
        case XTIROpShl:
            if (alo < 0 || blo != bhi || blo < 0 || blo > 30 || ahi > lim)
                return NO;
            *lo = alo << blo;
            *hi = ahi << blo;
            return YES;
        case XTIROpLShr:
            if (alo < 0 || blo != bhi || blo < 0 || blo > 62)
                return NO;
            *lo = alo >> blo;
            *hi = ahi >> blo;
            return YES;
        case XTIROpAnd:
            // At most the smaller of the two non-negative ones.
            if (alo >= 0 && blo >= 0)
                *hi = ahi < bhi ? ahi : bhi;
            else if (alo >= 0)
                *hi = ahi;
            else if (blo >= 0)
                *hi = bhi;
            else
                return NO;
            *lo = 0;
            return YES;
        case XTIROpURem:
            if (blo != bhi || blo <= 0)
                return NO;
            *lo = 0;
            *hi = blo - 1;
            if (alo >= 0 && ahi < *hi)
                *hi = ahi;
            return YES;
        case XTIROpUDiv:
            if (alo < 0 || blo != bhi || blo <= 0)
                return NO;
            *lo = alo / blo;
            *hi = ahi / blo;
            return YES;
        default:
            return NO;
        }
    }

// `v + c` or `v - c` (c a constant): the step, signed.
- (BOOL)stepOf:(XTIROperand*)inc value:(XTIRValueId)v step:(int64_t*)step
    {
    if (inc.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* d = self.defOf[@(inc.valueId)];
    if (!d || d.operands.count < 2)
        return NO;
    BOOL add = d.opcode == XTIROpAdd, sub = d.opcode == XTIROpSub;
    if (!add && !sub)
        return NO;
    XTIROperand* a = d.operands[0];
    XTIROperand* b = d.operands[1];
    int64_t c = 0;
    if (a.kind == XTIROperandKindUse && a.valueId == v && constWide(b, self.defOf, &c))
        {
        *step = add ? c : -c;
        return YES;
        }
    if (add && b.kind == XTIROperandKindUse && b.valueId == v && constWide(a, self.defOf, &c))
        {
        *step = c;
        return YES;
        }
    return NO;
    }

// A phi: the range of its entries, stretched toward the type's end its back
// edges move it (`v + c` up, `v - c` down); a cycle through it that is
// neither reads as the type's range.
- (BOOL)phiRange:(XTIRInsn*)def value:(XTIRValueId)v lo:(int64_t*)lo hi:(int64_t*)hi depth:(int)depth
    {
    if ([self.visiting containsObject:@(v)])
        return NO;
    [self.visiting addObject:@(v)];
    int64_t tlo = 0, thi = 0;
    typeRange(self.valueOf[@(v)].type, &tlo, &thi);
    BOOL up = NO, down = NO, seen = NO, ok = YES;
    int64_t elo = 0, ehi = 0;
    for (NSUInteger k = 1; k < def.operands.count && ok; k += 2)
        {
        XTIROperand* inc = def.operands[k];
        if (inc.kind == XTIROperandKindUse && inc.valueId == v)
            continue;
        int64_t step = 0;
        if ([self stepOf:inc value:v step:&step])
            {
            if (step > 0)
                up = YES;
            else if (step < 0)
                down = YES;
            continue;
            }
        int64_t ilo = 0, ihi = 0;
        if (![self range:inc lo:&ilo hi:&ihi depth:depth + 1])
            {
            ok = NO;
            break;
            }
        if (!seen || ilo < elo)
            elo = ilo;
        if (!seen || ihi > ehi)
            ehi = ihi;
        seen = YES;
        }
    [self.visiting removeObject:@(v)];
    if (!ok || !seen || (up && down))
        return NO;
    *lo = down ? tlo : elo;
    *hi = up ? thi : ehi;
    return YES;
    }

static XTIRICmpPredicate swapPred(XTIRICmpPredicate p, BOOL* ok)
    {
    *ok = YES;
    switch (p)
        {
        case XTIRICmpULT: return XTIRICmpUGT;
        case XTIRICmpUGT: return XTIRICmpULT;
        case XTIRICmpULE: return XTIRICmpUGE;
        case XTIRICmpUGE: return XTIRICmpULE;
        case XTIRICmpSLT: return XTIRICmpSGT;
        case XTIRICmpSGT: return XTIRICmpSLT;
        case XTIRICmpSLE: return XTIRICmpSGE;
        case XTIRICmpSGE: return XTIRICmpSLE;
        case XTIRICmpEQ: return p;
        default: *ok = NO; return p;
        }
    }

static XTIRICmpPredicate notPred(XTIRICmpPredicate p, BOOL* ok)
    {
    *ok = YES;
    switch (p)
        {
        case XTIRICmpULT: return XTIRICmpUGE;
        case XTIRICmpUGE: return XTIRICmpULT;
        case XTIRICmpULE: return XTIRICmpUGT;
        case XTIRICmpUGT: return XTIRICmpULE;
        case XTIRICmpSLT: return XTIRICmpSGE;
        case XTIRICmpSGE: return XTIRICmpSLT;
        case XTIRICmpSLE: return XTIRICmpSGT;
        case XTIRICmpSGT: return XTIRICmpSLE;
        default: *ok = NO; return p;
        }
    }

// `ICmp pred a, b` taken (or not): what it says of the value against the
// constant, or nil.
// `Select (ICmp ULT x, K), x, K`, the unsigned min of x and a constant K >= 0:
// K in *k. The port's beMinConst.
- (BOOL)minConstOf:(XTIROperand*)o k:(int64_t*)k
    {
    if (o.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* sel = self.defOf[@(o.valueId)];
    if (!sel || sel.opcode != XTIROpSelect || sel.operands.count != 3)
        return NO;
    XTIROperand* sc = sel.operands[0];
    XTIROperand* st = sel.operands[1];
    XTIROperand* sf = sel.operands[2];
    if (sc.kind != XTIROperandKindUse || st.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* cmp = self.defOf[@(sc.valueId)];
    if (!cmp || cmp.opcode != XTIROpICmp || cmp.predicate != XTIRICmpULT || cmp.operands.count < 2)
        return NO;
    int64_t kc = 0, kf = 0;
    if (cmp.operands[0].kind != XTIROperandKindUse || cmp.operands[0].valueId != st.valueId
        || !constWide(cmp.operands[1], self.defOf, &kc) || !constWide(sf, self.defOf, &kf) || kc != kf || kc < 0)
        return NO;
    *k = kc;
    return YES;
    }

- (nullable XTBeFact*)factOf:(XTIRInsn*)cmp taken:(BOOL)taken
    {
    XTIROperand* a = cmp.operands[0];
    XTIROperand* b = cmp.operands[1];
    XTIRICmpPredicate p = (XTIRICmpPredicate)cmp.predicate;
    int64_t c = 0;
    BOOL have = NO, ok = YES;
    XTIRValueId v = 0;
    if (a.kind == XTIROperandKindUse && constWide(b, self.defOf, &c))
        {
        v = a.valueId;
        have = YES;
        }
    else if (b.kind == XTIROperandKindUse && constWide(a, self.defOf, &c))
        {
        v = b.valueId;
        have = YES;
        p = swapPred(p, &ok);
        }
    // `a <u min(x, K)` taken: a is below K as surely as against K itself (the
    // outliner clamps a chunk's end to its loop's bound this way, 2026-10-25).
    // The port's beFactOf.
    else if (taken && a.kind == XTIROperandKindUse && (p == XTIRICmpULT || p == XTIRICmpULE)
             && [self minConstOf:b k:&c])
        {
        v = a.valueId;
        have = YES;
        }
    if (!have || !ok)
        return nil;
    if (!taken)
        {
        p = notPred(p, &ok);
        if (!ok)
            return nil;
        }
    XTIRValue* val = self.valueOf[@(v)];
    int64_t tlo = 0, thi = 0;
    if (!val || !typeRange(val.type, &tlo, &thi))
        return nil;
    BOOL uns = isUnsignedKind(val.type);
    XTBeFact* f = [XTBeFact new];
    f.v = v;
    f.lo = tlo;
    f.hi = thi;
    // An unsigned `<` against a non-negative constant bounds the value on both
    // sides, as its bits read unsigned, whatever its type.
    if ((p == XTIRICmpULT || p == XTIRICmpULE) && c >= 0)
        {
        f.lo = 0;
        f.hi = p == XTIRICmpULT ? c - 1 : c;
        return f;
        }
    if ((p == XTIRICmpUGT || p == XTIRICmpUGE) && uns && c >= 0)
        {
        f.lo = p == XTIRICmpUGT ? c + 1 : c;
        return f;
        }
    if (!uns && (p == XTIRICmpSLT || p == XTIRICmpSLE))
        {
        f.hi = p == XTIRICmpSLT ? c - 1 : c;
        return f;
        }
    if (!uns && (p == XTIRICmpSGT || p == XTIRICmpSGE))
        {
        f.lo = p == XTIRICmpSGT ? c + 1 : c;
        return f;
        }
    if (p == XTIRICmpEQ)
        {
        f.lo = f.hi = c;
        return f;
        }
    return nil;
    }

// Immediate dominators (the entry is its own), by the iterative intersection
// over a reverse postorder.
static NSMapTable* dominators(XTIRFunction* fn)
    {
    XTIRBlock* entry = fn.blocks.firstObject;
    NSMutableArray<XTIRBlock*>* order = [NSMutableArray array];
    NSHashTable* seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSMutableArray<XTIRBlock*>* stack = [NSMutableArray arrayWithObject:entry];
    NSMutableArray<NSNumber*>* next = [NSMutableArray arrayWithObject:@0];
    [seen addObject:entry];
    while (stack.count)
        {
        XTIRBlock* top = stack.lastObject;
        NSUInteger k = next.lastObject.unsignedIntegerValue;
        NSArray<XTIROperand*>* tops = top.terminator.operands;
        BOOL pushed = NO;
        while (k < tops.count && !pushed)
            {
            XTIROperand* o = tops[k];
            k++;
            if (o.kind == XTIROperandKindBlock && o.blockRef && ![seen containsObject:o.blockRef])
                {
                next[next.count - 1] = @(k);
                [seen addObject:o.blockRef];
                [stack addObject:o.blockRef];
                [next addObject:@0];
                pushed = YES;
                }
            }
        if (!pushed)
            {
            [order addObject:top];
            [stack removeLastObject];
            [next removeLastObject];
            }
        }
    NSMapTable* po = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
                                          valueOptions:NSPointerFunctionsStrongMemory];
    for (NSUInteger i = 0; i < order.count; i++)
        [po setObject:@(i) forKey:order[i]];
    NSMapTable* preds = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
                                             valueOptions:NSPointerFunctionsStrongMemory];
    for (XTIRBlock* bb in order)
        for (XTIROperand* o in bb.terminator.operands)
            {
            if (o.kind != XTIROperandKindBlock || !o.blockRef)
                continue;
            NSMutableArray* ps = [preds objectForKey:o.blockRef];
            if (!ps)
                {
                ps = [NSMutableArray array];
                [preds setObject:ps forKey:o.blockRef];
                }
            [ps addObject:bb];
            }
    NSMapTable* idom = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
                                            valueOptions:NSPointerFunctionsObjectPointerPersonality];
    [idom setObject:entry forKey:entry];
    BOOL changed = YES;
    while (changed)
        {
        changed = NO;
        for (NSUInteger r = order.count; r > 0; r--)
            {
            XTIRBlock* bb = order[r - 1];
            if (bb == entry)
                continue;
            XTIRBlock* nd = nil;
            for (XTIRBlock* p in [preds objectForKey:bb])
                {
                if (![idom objectForKey:p])
                    continue;
                if (!nd)
                    {
                    nd = p;
                    continue;
                    }
                XTIRBlock* a = p;
                XTIRBlock* b = nd;
                for (int guard = 0; a != b && guard < 100000; guard++)
                    {
                    while ([[po objectForKey:a] unsignedIntegerValue] < [[po objectForKey:b] unsignedIntegerValue])
                        a = [idom objectForKey:a];
                    while ([[po objectForKey:b] unsignedIntegerValue] < [[po objectForKey:a] unsignedIntegerValue])
                        b = [idom objectForKey:b];
                    }
                nd = a;
                }
            if (nd && [idom objectForKey:bb] != nd)
                {
                [idom setObject:nd forKey:bb];
                changed = YES;
                }
            }
        }
    return idom;
    }

// Each block a guard's edge is the only way into: the facts that edge gives.
- (NSMapTable*)guardFacts:(XTIRFunction*)fn
    {
    NSMapTable* preds = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
                                             valueOptions:NSPointerFunctionsStrongMemory];
    for (XTIRBlock* b in fn.blocks)
        for (XTIROperand* o in b.terminator.operands)
            if (o.kind == XTIROperandKindBlock && o.blockRef)
                [preds setObject:@([[preds objectForKey:o.blockRef] unsignedIntegerValue] + 1) forKey:o.blockRef];
    NSMapTable* out = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
                                           valueOptions:NSPointerFunctionsStrongMemory];
    for (XTIRBlock* H in fn.blocks)
        {
        XTIRInsn* t = H.terminator;
        if (!t || t.opcode != XTIROpCondBranch || t.operands.count < 3)
            continue;
        XTIROperand* c = t.operands[0];
        if (c.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* cmp = self.defOf[@(c.valueId)];
        if (!cmp || cmp.opcode != XTIROpICmp || cmp.operands.count < 2)
            continue;
        for (NSUInteger e = 1; e <= 2; e++)
            {
            XTIRBlock* T = t.operands[e].blockRef;
            if (!T || T == H || [[preds objectForKey:T] unsignedIntegerValue] != 1)
                continue;
            XTBeFact* f = [self factOf:cmp taken:(e == 1)];
            if (!f)
                continue;
            NSMutableArray* fs = [out objectForKey:T];
            if (!fs)
                {
                fs = [NSMutableArray array];
                [out setObject:fs forKey:T];
                }
            [fs addObject:f];
            }
        }
    return out;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    self.mod = mod;
    XTIRSymbol* chk = [mod symbolForName:@"_xt_check_bounds_n"];
    XTIRSymbol* hchk = [mod symbolForName:@"_xt_check_bounds"];
    XTIRSymbolId chkId = chk ? [mod.symbols indexOfObjectIdenticalTo:chk] : (XTIRSymbolId)NSNotFound;
    XTIRSymbolId hchkId = hchk ? [mod.symbols indexOfObjectIdenticalTo:hchk] : (XTIRSymbolId)NSNotFound;
    for (XTIRFunction* fn in mod.functions)
        {
        if (fn.blocks.count == 0)
            continue;
        self.defOf = [NSMutableDictionary dictionary];
        self.valueOf = [NSMutableDictionary dictionary];
        for (XTIRValue* v in fn.values.allValues)
            self.valueOf[@(v.valueId)] = v;
        for (XTIRBlock* b in fn.blocks)
            {
            for (XTIRInsn* p in b.phiNodes)
                if (p.result)
                    self.defOf[@(p.result.valueId)] = p;
            for (XTIRInsn* n in b.instructions)
                if (n.result)
                    self.defOf[@(n.result.valueId)] = n;
            }
        BOOL any = NO;
        for (XTIRBlock* bb in fn.blocks)
            for (XTIRInsn* n in bb.instructions)
                if ((chk && isCall(n, chkId, 6)) || (hchk && isCall(n, hchkId, 5)) || [self wideIndexOf:n])
                    any = YES;
        if (!any)
            continue;
        NSMapTable* idom = dominators(fn);
        NSMapTable* blockFacts = [self guardFacts:fn];
        BOOL removed = NO;
        for (XTIRBlock* X in fn.blocks)
            {
            self.facts = [NSMutableArray array];
            XTIRBlock* d = X;
            for (int guard = 0; d && guard < 4096; guard++)
                {
                NSArray* fs = [blockFacts objectForKey:d];
                if (fs)
                    [self.facts addObjectsFromArray:fs];
                XTIRBlock* up = [idom objectForKey:d];
                d = up == d ? nil : up;
                }
            // A subscript widened from 32 bits (C's `a[i]` reads `zext i` into an
            // i64 index) uses the 32-bit value itself when that is proved inside
            // [0, 2^31): the same element, and the iv-indexed shape the
            // vectoriser takes. Mirrors the self-hosted pass.
            for (XTIRInsn* ea in X.instructions)
                {
                XTIROperand* narrow = [self wideIndexOf:ea];
                int64_t wlo = 0, whi = 0;
                self.visiting = [NSMutableSet set];
                if (narrow && [self range:narrow lo:&wlo hi:&whi depth:0] && wlo >= 0 && whi <= 0x7FFFFFFF)
                    {
                    NSMutableArray<XTIROperand*>* ops = [ea.operands mutableCopy];
                    ops[1] = narrow;
                    [ea replaceOperands:ops];
                    }
                }
            NSUInteger i = 0;
            while (i < X.instructions.count)
                {
                XTIRInsn* n = X.instructions[i];
                int64_t count = 0, lo = 0, hi = 0;
                self.visiting = [NSMutableSet set];
                // A fixed-size array's check carries its count; a heap
                // pointer's has one when the pointer is `new T[c]`'s own
                // result, c a constant.
                BOOL fixed = chk && isCall(n, chkId, 6);
                BOOL known = fixed ? constWide(n.operands[3], self.defOf, &count)
                                   : (hchk && isCall(n, hchkId, 5) && [self newCount:n.operands[1] count:&count]);
                if (known && [self range:n.operands[2] lo:&lo hi:&hi depth:0] && lo >= 0 && hi < count && n.memoryResult)
                    {
                    // The call's memory goes to whatever it came from.
                    XTIRValueId old = n.memoryResult.valueId;
                    XTIROperand* to = n.operands.lastObject;
                    for (XTIRBlock* b in fn.blocks)
                        {
                        for (XTIRInsn* p in b.phiNodes)
                            replaceUses(p, old, to);
                        for (XTIRInsn* m in b.instructions)
                            replaceUses(m, old, to);
                        if (b.terminator)
                            replaceUses(b.terminator, old, to);
                        }
                    [X.instructions removeObjectAtIndex:i];
                    removed = YES;
                    continue;
                    }
                i++;
                }
            }
        // An `if` body that held a check was a call, so if-conversion left it
        // a branch: with the checks gone it may be a select now (branch_mix
        // checked kept main's four selects as branches). Only the functions
        // checks came out of, so an unchecked build is untouched.
        if (removed && self.profile && self.profile.ifConvertsPredicates && !getenv("XTIC_OFF"))
            {
            // What the checks leave (their site strings and counts) goes,
            // then the arms' loads, as before the first if-conversion: the
            // checks kept each arm's `a[i]` its own load, which an arm may not
            // speculate.
            [[[XTIROptDeadCode alloc] init] runOnFunction:fn];
            XTIROptRedundantLoadCSE* cse = [[XTIROptRedundantLoadCSE alloc] init];
            cse.crossBlock = self.profile.hoistsLocalAddr;
            [cse runOnFunction:fn];
            XTIROptIfConvert* ic = [[XTIROptIfConvert alloc] init];
            ic.profile = self.profile;
            [ic runOnFunction:fn];
            }
        }
    self.defOf = nil;
    self.valueOf = nil;
    self.facts = nil;
    self.visiting = nil;
    self.mod = nil;
    return YES;
    }

@end
