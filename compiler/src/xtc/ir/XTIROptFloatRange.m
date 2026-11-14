#import "XTIROptFloatRange.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIROpcode.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRSupport.h"

// ── float-range ──────────────────────────────────────────────────────────
//
// xc defines an out-of-range float-to-integer conversion as 0 (and NaN as 0),
// so FpToUI/FpToSI carry a range check: on arm64 `fcvtzu x`, a compare and a
// select where C's cast is one `fcvtzu w` (#23). When the operand is known
// finite and in range, the check cannot fire, and the conversion is marked
// XTIRConvUnchecked, the form C's casts already take; every back end gives the
// same answer for an in-range value either way.
//
// The range is kept in integers only, never host floating point, so both
// compilers decide alike: for a float value, a bound |x| <= 2^E, whether x >= 0
// (or -0), and that it is finite (a value with no entry may be anything, NaN
// included). Exact rounding is monotonic and 2^E is representable, so a
// rounded result keeps the bound. The sources: a constant (its exponent), an
// integer converted (its width, an And's mask, a shift), a divide or multiply
// by a constant, sums and differences, a select of two known values, and a
// loop phi that doubles (or scales by a constant) once a trip on a counted
// loop: perlin's `x = x * 2` over four octaves, from `(float)(i % W) / 256`.
// As the port (selfhost/opt/OptFloatRange.xc), step for step.

@implementation XTIROptFloatRange

- (NSString*)passName
    {
    return @"float-range";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

typedef struct
    {
    NSMutableDictionary<NSNumber*, NSNumber*>* ex; // valueId -> E
    NSMutableSet<NSNumber*>* nn;                   // valueIds with x >= 0 (or -0)
    NSDictionary<NSNumber*, XTIRInsn*>* defOf;
    XTIRFunction* fn;
    } FRState;

static BOOL frIsConv(XTIRInsn* n)
    {
    return (n.opcode == XTIROpFpToUI || n.opcode == XTIROpFpToSI) && n.predicate == XTIRConvChecked && n.result &&
           n.operands.count >= 1;
    }

static int64_t frBits(XTIRTypeKind k)
    {
    switch (k)
        {
        case XTIRTypeKindI8:
        case XTIRTypeKindU8:
            return 8;
        case XTIRTypeKindI16:
        case XTIRTypeKindU16:
            return 16;
        case XTIRTypeKindI32:
        case XTIRTypeKindU32:
            return 32;
        case XTIRTypeKindI64:
        case XTIRTypeKindU64:
            return 64;
        default:
            return 0;
        }
    }

static BOOL frIsFloat(XTIRTypeKind k)
    {
    return k == XTIRTypeKindF32 || k == XTIRTypeKindF64;
    }

static XTIRTypeKind frKindOf(FRState* s, XTIRValueId v)
    {
    XTIRValue* val = s->fn.values[@(v)];
    return val ? val.type.kind : XTIRTypeKindVoid;
    }

// Record v's bound, when usable for its type (an F32 near its top may round to
// infinity). YES when v had none before.
static BOOL frSet(FRState* s, XTIRValue* v, int64_t e, BOOL isNn)
    {
    if (!v || s->ex[@(v.valueId)])
        return NO;
    int64_t cap = v.type.kind == XTIRTypeKindF32 ? 120 : 1000;
    if (e > cap)
        return NO;
    if (e < -1100)
        e = -1100;
    s->ex[@(v.valueId)] = @(e);
    if (isNn)
        [s->nn addObject:@(v.valueId)];
    return YES;
    }

// A finite constant's bound from its double bits: |c| <= 2^E.
static BOOL frConstBound(uint64_t bits, int64_t* e, BOOL* isNn)
    {
    uint64_t ef = (bits >> 52) & 0x7FF;
    uint64_t mant = bits & 0xFFFFFFFFFFFFFULL;
    if (ef == 0x7FF)
        return NO;
    *isNn = (bits >> 63) == 0 || (ef == 0 && mant == 0);
    if (ef == 0)
        *e = mant == 0 ? -1100 : -1022;
    else
        *e = mant == 0 ? (int64_t)ef - 1023 : (int64_t)ef - 1022;
    return YES;
    }

// An operand's bound; a float constant operand is read directly.
static BOOL frGet(FRState* s, XTIROperand* o, int64_t* e, BOOL* isNn)
    {
    if (o.kind == XTIROperandKindImmF)
        return frConstBound(o.floatRawBytes, e, isNn);
    if (o.kind != XTIROperandKindUse)
        return NO;
    NSNumber* eo = s->ex[@(o.valueId)];
    if (!eo)
        return NO;
    *e = eo.longLongValue;
    *isNn = [s->nn containsObject:@(o.valueId)];
    return YES;
    }

// The float constant an operand is (directly or through its Const), as bits.
static BOOL frConstBits(FRState* s, XTIROperand* o, uint64_t* bits)
    {
    if (o.kind == XTIROperandKindImmF)
        {
        *bits = o.floatRawBytes;
        return YES;
        }
    if (o.kind != XTIROperandKindUse)
        return NO;
    XTIRInsn* d = s->defOf[@(o.valueId)];
    if (!d || d.opcode != XTIROpConst || d.operands.count < 1 || d.operands[0].kind != XTIROperandKindImmF)
        return NO;
    *bits = d.operands[0].floatRawBytes;
    return YES;
    }

// An integer constant, directly or through a Const and any ZExt/SExt/Trunc.
static BOOL frIntConst(FRState* s, XTIROperand* o, int64_t* out)
    {
    if (o.kind == XTIROperandKindImmI)
        {
        *out = o.intValue;
        return YES;
        }
    if (o.kind != XTIROperandKindUse)
        return NO;
    XTIRValueId cur = o.valueId;
    for (int d = 0; d < 16; d++)
        {
        XTIRInsn* di = s->defOf[@(cur)];
        if (!di || di.operands.count < 1)
            return NO;
        XTIROperand* k = di.operands[0];
        if (di.opcode == XTIROpConst)
            {
            if (k.kind != XTIROperandKindImmI)
                return NO;
            *out = k.intValue;
            return YES;
            }
        if (di.opcode != XTIROpZExt && di.opcode != XTIROpSExt && di.opcode != XTIROpTrunc)
            return NO;
        if (k.kind == XTIROperandKindImmI)
            {
            *out = k.intValue;
            return YES;
            }
        if (k.kind != XTIROperandKindUse)
            return NO;
        cur = k.valueId;
        }
    return NO;
    }

// The exponent bound of an integer converted to float: its width, or less when
// it is an And with a constant mask or a right shift by a constant.
static int64_t frIntBound(FRState* s, XTIROperand* o, BOOL isSigned)
    {
    if (o.kind == XTIROperandKindImmI)
        {
        int64_t v = o.intValue;
        if (v < 0)
            v = 0 - v;
        int64_t b = 0;
        while (b < 63 && ((int64_t)1 << b) < v)
            b++;
        return b;
        }
    if (o.kind != XTIROperandKindUse)
        return 64;
    int64_t w = frBits(frKindOf(s, o.valueId));
    if (w == 0)
        w = 64;
    if (isSigned)
        return w - 1;
    XTIRInsn* di = s->defOf[@(o.valueId)];
    if (!di)
        return w;
    if (di.operands.count == 2)
        {
        XTIROperand* c = di.operands[1];
        int64_t k = 0;
        if (di.opcode == XTIROpAnd && frIntConst(s, c, &k) && k >= 0)
            {
            int64_t b = 0;
            while (b < w && ((int64_t)1 << b) <= k)
                b++;
            return b < w ? b : w;
            }
        if (di.opcode == XTIROpLShr && frIntConst(s, c, &k) && k > 0 && k < w)
            return w - k;
        }
    if (di.opcode == XTIROpZExt && di.operands.count >= 1)
        {
        XTIROperand* src = di.operands[0];
        if (src.kind == XTIROperandKindUse)
            {
            int64_t sw = frBits(frKindOf(s, src.valueId));
            if (sw > 0 && sw < w)
                return sw;
            }
        }
    return w;
    }

// One instruction's bound from its operands'. YES when it gained one.
static BOOL frInsn(FRState* s, XTIRInsn* n)
    {
    XTIRValue* r = n.result;
    if (!r || !frIsFloat(r.type.kind) || s->ex[@(r.valueId)])
        return NO;
    XTIROpcode op = n.opcode;
    NSUInteger nops = n.operands.count;
    int64_t ea = 0, eb = 0;
    BOOL na = NO, nb = NO;
    if (op == XTIROpConst && nops >= 1)
        {
        XTIROperand* k = n.operands[0];
        if (k.kind == XTIROperandKindImmF && frConstBound(k.floatRawBytes, &ea, &na))
            return frSet(s, r, ea, na);
        return NO;
        }
    if (op == XTIROpUIToFp && nops >= 1)
        return frSet(s, r, frIntBound(s, n.operands[0], NO), YES);
    if (op == XTIROpSIToFp && nops >= 1)
        return frSet(s, r, frIntBound(s, n.operands[0], YES), NO);
    if ((op == XTIROpCopy || op == XTIROpFpExt || op == XTIROpFpTrunc || op == XTIROpFNeg) && nops >= 1)
        {
        if (!frGet(s, n.operands[0], &ea, &na))
            return NO;
        return frSet(s, r, ea, na && op != XTIROpFNeg);
        }
    if (op == XTIROpSelect && nops == 3)
        {
        if (!frGet(s, n.operands[1], &ea, &na) || !frGet(s, n.operands[2], &eb, &nb))
            return NO;
        return frSet(s, r, ea > eb ? ea : eb, na && nb);
        }
    if (nops != 2)
        return NO;
    XTIROperand *a = n.operands[0], *b = n.operands[1];
    if (op == XTIROpFDiv)
        {
        // Only by a nonzero normal constant: |b| >= 2^(e-1023).
        uint64_t bits = 0;
        if (!frConstBits(s, b, &bits) || !frGet(s, a, &ea, &na))
            return NO;
        uint64_t ef = (bits >> 52) & 0x7FF;
        if (ef == 0 || ef == 0x7FF)
            return NO;
        return frSet(s, r, ea - ((int64_t)ef - 1023), na && (bits >> 63) == 0);
        }
    if (!frGet(s, a, &ea, &na) || !frGet(s, b, &eb, &nb))
        return NO;
    int64_t mx = ea > eb ? ea : eb;
    if (op == XTIROpFMul)
        return frSet(s, r, ea + eb, na && nb);
    if (op == XTIROpFAdd)
        return frSet(s, r, mx + 1, na && nb);
    if (op == XTIROpFSub)
        return frSet(s, r, mx + 1, NO);
    return NO;
    }

// An integer compare at a width, unsigned or signed by its predicate.
static BOOL frICmp(uint8_t p, int64_t a, int64_t b, int64_t w)
    {
    uint64_t mask = w >= 64 ? ~0ULL : (((uint64_t)1 << w) - 1);
    uint64_t ua = (uint64_t)a & mask, ub = (uint64_t)b & mask;
    int64_t sa = a, sb = b;
    if (w < 64)
        {
        uint64_t sbit = (uint64_t)1 << (w - 1);
        sa = (int64_t)((ua ^ sbit) - sbit);
        sb = (int64_t)((ub ^ sbit) - sbit);
        }
    switch (p)
        {
        case XTIRICmpEQ: return ua == ub;
        case XTIRICmpNE: return ua != ub;
        case XTIRICmpULT: return ua < ub;
        case XTIRICmpULE: return ua <= ub;
        case XTIRICmpUGT: return ua > ub;
        case XTIRICmpUGE: return ua >= ub;
        case XTIRICmpSLT: return sa < sb;
        case XTIRICmpSLE: return sa <= sb;
        case XTIRICmpSGT: return sa > sb;
        case XTIRICmpSGE: return sa >= sb;
        default: return NO;
        }
    }

// The most times H's body runs, from its counted latch L (entered from block
// E): a header phi with a constant start and a constant positive step, and L's
// CondBranch back to H on that counter (or its next value) against a constant.
// 0 when it cannot be bounded (at most 256).
static uint32_t frTrip(FRState* s, XTIRBlock* H, XTIRBlock* L, XTIRBlock* E)
    {
    XTIRInsn* t = L.terminator;
    if (!t || t.opcode != XTIROpCondBranch || t.operands.count != 3)
        return 0;
    XTIROperand *c = t.operands[0], *tt = t.operands[1], *tf = t.operands[2];
    BOOL toT = tt.kind == XTIROperandKindBlock && tt.blockRef == H;
    BOOL toF = tf.kind == XTIROperandKindBlock && tf.blockRef == H;
    if (toT == toF || c.kind != XTIROperandKindUse)
        return 0;
    XTIRInsn* cmp = s->defOf[@(c.valueId)];
    if (!cmp || cmp.opcode != XTIROpICmp || cmp.operands.count != 2)
        return 0;
    XTIROperand* ca = cmp.operands[0];
    int64_t bound = 0;
    if (ca.kind != XTIROperandKindUse || !frIntConst(s, cmp.operands[1], &bound))
        return 0;
    for (XTIRInsn* q in H.phiNodes)
        {
        if (!q.result || frBits(q.result.type.kind) == 0 || q.operands.count != 4)
            continue;
        XTIROperand *qinit = nil, *qnext = nil;
        for (NSUInteger k = 0; k < 4; k += 2)
            {
            XTIROperand* qb = q.operands[k];
            if (qb.kind != XTIROperandKindBlock)
                continue;
            if (qb.blockRef == L)
                qnext = q.operands[k + 1];
            else if (qb.blockRef == E)
                qinit = q.operands[k + 1];
            }
        int64_t start = 0;
        if (!qinit || !qnext || !frIntConst(s, qinit, &start))
            continue;
        if (qnext.kind != XTIROperandKindUse)
            continue;
        XTIRInsn* add = s->defOf[@(qnext.valueId)];
        if (!add || add.opcode != XTIROpAdd || add.operands.count != 2)
            continue;
        XTIROperand *a0 = add.operands[0], *a1 = add.operands[1];
        int64_t step = 0;
        if (a0.kind == XTIROperandKindUse && a0.valueId == q.result.valueId && frIntConst(s, a1, &step))
            {
            }
        else if (a1.kind == XTIROperandKindUse && a1.valueId == q.result.valueId && frIntConst(s, a0, &step))
            {
            }
        else
            continue;
        if (step <= 0)
            continue;
        BOOL onNext = ca.valueId == qnext.valueId;
        if (!onNext && ca.valueId != q.result.valueId)
            continue;
        // The body runs for the counter's values start, start+step, ... and
        // after each L tests the counter (or its next value) and goes back to
        // H while the compare says so.
        uint32_t runs = 1;
        int64_t v = start;
        while (runs <= 256)
            {
            int64_t tested = onNext ? v + step : v;
            BOOL cnd = frICmp(cmp.predicate, tested, bound, frBits(q.result.type.kind));
            if (cnd != toT)
                return runs;
            v += step;
            runs++;
            }
        return 0;
        }
    return 0;
    }

// A phi's bound: every incoming known (the larger), or a loop phi that scales
// by a constant once a trip of a counted loop.
static BOOL frPhi(FRState* s, XTIRBlock* H, XTIRInsn* p)
    {
    XTIRValue* r = p.result;
    if (!r || !frIsFloat(r.type.kind) || s->ex[@(r.valueId)])
        return NO;
    NSUInteger np = p.operands.count;
    int64_t emax = -1100;
    BOOL allNn = YES;
    BOOL all = np >= 2;
    for (NSUInteger k = 0; all && k + 1 < np; k += 2)
        {
        int64_t e = 0;
        BOOL isNn = NO;
        if (!frGet(s, p.operands[k + 1], &e, &isNn))
            all = NO;
        else
            {
            if (e > emax)
                emax = e;
            allNn = allNn && isNn;
            }
        }
    if (all)
        return frSet(s, r, emax, allNn);
    if (np != 4)
        return NO;
    // init from one edge, next = p * c (or p + p) from a latch that branches
    // back to H on a counted compare.
    for (NSUInteger side = 0; side < 2; side++)
        {
        XTIROperand* lb = p.operands[side * 2];
        XTIROperand* lv = p.operands[side * 2 + 1];
        XTIROperand* iv = p.operands[(1 - side) * 2 + 1];
        XTIROperand* ib = p.operands[(1 - side) * 2];
        if (lb.kind != XTIROperandKindBlock || !lb.blockRef || ib.kind != XTIROperandKindBlock)
            continue;
        if (lv.kind != XTIROperandKindUse)
            continue;
        int64_t ei = 0;
        BOOL ni = NO;
        if (!frGet(s, iv, &ei, &ni))
            continue;
        XTIRInsn* nx = s->defOf[@(lv.valueId)];
        if (!nx || nx.operands.count != 2)
            continue;
        XTIROperand *x0 = nx.operands[0], *x1 = nx.operands[1];
        BOOL s0 = x0.kind == XTIROperandKindUse && x0.valueId == r.valueId;
        BOOL s1 = x1.kind == XTIROperandKindUse && x1.valueId == r.valueId;
        int64_t grow = 0;
        if (nx.opcode == XTIROpFAdd && s0 && s1)
            grow = 1;
        else if (nx.opcode == XTIROpFMul && (s0 || s1) && !(s0 && s1))
            {
            uint64_t bits = 0;
            if (!frConstBits(s, s0 ? x1 : x0, &bits))
                continue;
            uint64_t ef = (bits >> 52) & 0x7FF;
            uint64_t mant = bits & 0xFFFFFFFFFFFFFULL;
            if (ef == 0x7FF || (bits >> 63) != 0)
                continue;
            int64_t ce = ef == 0 ? -1022 : (mant == 0 ? (int64_t)ef - 1023 : (int64_t)ef - 1022);
            grow = ce > 0 ? ce : 0;
            }
        else
            continue;
        uint32_t trip = frTrip(s, H, lb.blockRef, ib.blockRef);
        if (trip == 0)
            continue;
        return frSet(s, r, ei + (int64_t)(trip - 1) * grow, ni);
        }
    return NO;
    }

- (BOOL)runOnModule:(XTIRModule*)mod errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    for (XTIRFunction* fn in mod.functions)
        {
        BOOL any = NO;
        for (XTIRBlock* bb in fn.blocks)
            for (XTIRInsn* n in bb.instructions)
                if (frIsConv(n))
                    any = YES;
        if (!any)
            continue;
        NSMutableDictionary<NSNumber*, XTIRInsn*>* defOf = [NSMutableDictionary dictionary];
        for (XTIRBlock* bb in fn.blocks)
            {
            for (XTIRInsn* n in bb.phiNodes)
                if (n.result)
                    defOf[@(n.result.valueId)] = n;
            for (XTIRInsn* n in bb.instructions)
                if (n.result)
                    defOf[@(n.result.valueId)] = n;
            }
        FRState st = {[NSMutableDictionary dictionary], [NSMutableSet set], defOf, fn};
        for (int sweep = 0; sweep < 4; sweep++)
            {
            BOOL changed = NO;
            for (XTIRBlock* bb in fn.blocks)
                {
                for (XTIRInsn* p in bb.phiNodes)
                    if (frPhi(&st, bb, p))
                        changed = YES;
                for (XTIRInsn* n in bb.instructions)
                    if (frInsn(&st, n))
                        changed = YES;
                }
            if (!changed)
                break;
            }
        for (XTIRBlock* bb in fn.blocks)
            for (XTIRInsn* n in bb.instructions)
                {
                if (!frIsConv(n))
                    continue;
                XTIROperand* o = n.operands[0];
                if (o.kind != XTIROperandKindUse)
                    continue;
                NSNumber* eo = st.ex[@(o.valueId)];
                if (!eo)
                    continue;
                int64_t e = eo.longLongValue;
                int64_t w = frBits(n.result.type.kind);
                if (w == 0)
                    continue;
                BOOL ok = n.opcode == XTIROpFpToUI ? ([st.nn containsObject:@(o.valueId)] && e <= w - 1) : e <= w - 2;
                if (ok)
                    n.predicate = XTIRConvUnchecked;
                }
        }
    return YES; // the pipeline reads NO as a failure
    }

@end
