// OptFloatRange.xc — the float-range pass, as src/xtc/ir/XTIROptFloatRange.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptStrengthReduce>

    class Opt (FloatRange)
    {

    // ── float-range ──────────────────────────────────────────────────────
    //
    // xc defines an out-of-range float-to-integer conversion as 0 (and NaN as
    // 0), so FpToUI/FpToSI carry a range check: on arm64 `fcvtzu x`, a
    // compare and a select where C's cast is one `fcvtzu w` (#23). When the
    // operand is known finite and in range, the check cannot fire, and the
    // conversion is marked `unchecked`, the form C's casts already take; every
    // back end gives the same answer for an in-range value either way.
    //
    // The range is kept in integers only, never host floating point, so both
    // compilers decide alike: for a float value, a bound |x| <= 2^E, whether
    // x >= 0 (or -0), and that it is finite (a value with no entry may be
    // anything, NaN included). Exact rounding is monotonic and 2^E is
    // representable, so a rounded result keeps the bound. The sources: a
    // constant (its exponent), an integer converted (its width, an And's mask,
    // a shift), a divide or multiply by a constant, sums and differences, a
    // select of two known values, and a loop phi that doubles (or scales by a
    // constant) once a trip on a counted loop: perlin's `x = x * 2` over four
    // octaves, from `(float)(i % W) / 256`.
    final void floatRange(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            self.frFunc((IRFunc*)m.funcs().get(f));
        }

    final void frFunc(IRFunc* fn)
        {
        Map* defOf = self.defMap(fn);
        Map* ex = new Map();   // IRValue -> Number(E + 4096)
        Map* nn = new Map();   // IRValue -> Number(1) when x >= 0 (or -0)
        bool any = false;
        for (u32 b = (u32)0; b < fn.blocks().count() && !any; b = b + (u32)1)
            {
            Array* ins = ((IRBlock*)fn.blocks().get(b)).insns();
            for (u32 i = (u32)0; i < ins.count(); i = i + (u32)1)
                if (frIsConv((IRInsn*)ins.get(i)))
                    any = true;
            }
        if (!any)
            return;
        for (u32 sweep = (u32)0; sweep < (u32)4; sweep = sweep + (u32)1)
            {
            bool changed = false;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                    if (self.frPhi(fn, bb, (IRInsn*)bb.phis().get(i), defOf, ex, nn))
                        changed = true;
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    if (self.frInsn((IRInsn*)bb.insns().get(i), defOf, ex, nn))
                        changed = true;
                }
            if (!changed)
                break;
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            Array* ins = ((IRBlock*)fn.blocks().get(b)).insns();
            for (u32 i = (u32)0; i < ins.count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)ins.get(i);
                if (!frIsConv(n))
                    continue;
                IROperand* o = (IROperand*)n.ops().get((u32)0);
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                    continue;
                Object* eo = ex.get((Hashable*)o.val());
                if (eo == (Object*)0)
                    continue;
                i64 e = (i64)((Number*)eo).asU32() - (i64)4096;
                i64 w = (i64)frBits(n.res().ty());
                if (w == (i64)0)
                    continue;
                bool ok = n.op().equals(String.withCString("FpToUI"))
                              ? (nn.get((Hashable*)o.val()) != (Object*)0 && e <= w - (i64)1)
                              : e <= w - (i64)2;
                if (ok)
                    n.setPred(String.withCString("unchecked"));
                }
            }
        }

    // A checked float-to-integer conversion.
    static bool frIsConv(IRInsn* n)
        {
        return (n.op().equals(String.withCString("FpToUI")) || n.op().equals(String.withCString("FpToSI")))
               && n.pred() == (String*)0 && n.res() != (IRValue*)0 && n.ops().count() >= (u32)1;
        }

    // The bit width of an integer type, 0 for anything else.
    static u32 frBits(String* t)
        {
        if (t.equals(String.withCString("I8")) || t.equals(String.withCString("U8")))
            return (u32)8;
        if (t.equals(String.withCString("I16")) || t.equals(String.withCString("U16")))
            return (u32)16;
        if (t.equals(String.withCString("I32")) || t.equals(String.withCString("U32")))
            return (u32)32;
        if (t.equals(String.withCString("I64")) || t.equals(String.withCString("U64")))
            return (u32)64;
        return (u32)0;
        }

    static bool frIsFloat(String* t)
        {
        return t.equals(String.withCString("F32")) || t.equals(String.withCString("F64"));
        }

    // Record v's bound, when it is a usable one for v's type (an F32 near its
    // top may round to infinity). True when v had none before.
    final bool frSet(IRValue* v, i64 e, bool isNn, Map* ex, Map* nn)
        {
        if (v == (IRValue*)0 || ex.get((Hashable*)v) != (Object*)0)
            return false;
        i64 cap = v.ty().equals(String.withCString("F32")) ? (i64)120 : (i64)1000;
        if (e > cap)
            return false;
        if (e < (i64)-1100)
            e = (i64)-1100;
        ex.set((Hashable*)v, (Object*)Number.withU32((u32)(e + (i64)4096)));
        if (isNn)
            nn.set((Hashable*)v, (Object*)Number.withU32((u32)1));
        return true;
        }

    // An operand's bound: true and *e/*isNn set when it has one. A float
    // constant operand is read directly.
    final bool frGet(IROperand* o, Map* defOf, Map* ex, Map* nn, i64* e, bool* isNn)
        {
        if (o.kind() == (u8)OPK_IMMF)
            return self.frConstBound(o.fpHex(), e, isNn);
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return false;
        Object* eo = ex.get((Hashable*)o.val());
        if (eo == (Object*)0)
            return false;
        e[0] = (i64)((Number*)eo).asU32() - (i64)4096;
        isNn[0] = nn.get((Hashable*)o.val()) != (Object*)0;
        return true;
        }

    // A finite constant's bound from its double bits: |c| <= 2^E.
    final bool frConstBound(String* hex, i64* e, bool* isNn)
        {
        u64 bits = (u64)0;
        if (!self.srfBits(hex, &bits))
            return false;
        u64 ef = (bits >> (u64)52) & (u64)$7FF;
        u64 mant = bits & (u64)$F_FFFF_FFFF_FFFF;
        if (ef == (u64)$7FF)
            return false;
        isNn[0] = (bits >> (u64)63) == (u64)0 || (ef == (u64)0 && mant == (u64)0);
        if (ef == (u64)0)
            e[0] = mant == (u64)0 ? (i64)-1100 : (i64)-1022;
        else
            e[0] = mant == (u64)0 ? (i64)ef - (i64)1023 : (i64)ef - (i64)1022;
        return true;
        }

    // The float constant an operand is (directly or through its Const), as
    // double bits; false when it is not one.
    final bool frConstBits(IROperand* o, Map* defOf, u64* bits)
        {
        String* hex = (String*)0;
        if (o.kind() == (u8)OPK_IMMF)
            hex = o.fpHex();
        else if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
            {
            Object* d = defOf.get((Hashable*)o.val());
            if (d == (Object*)0)
                return false;
            IRInsn* di = (IRInsn*)d;
            if (!di.op().equals(String.withCString("Const")) || di.ops().count() < (u32)1)
                return false;
            IROperand* k = (IROperand*)di.ops().get((u32)0);
            if (k.kind() != (u8)OPK_IMMF)
                return false;
            hex = k.fpHex();
            }
        if (hex == (String*)0)
            return false;
        return self.srfBits(hex, bits);
        }

    // The exponent bound of an integer converted to float: its width, or less
    // when it is an And with a constant mask or a right shift by a constant.
    final i64 frIntBound(IROperand* o, Map* defOf, bool isSigned)
        {
        if (o.kind() == (u8)OPK_IMMI)
            {
            i64 v = o.imm();
            if (v < (i64)0)
                v = (i64)0 - v;
            i64 b = (i64)0;
            while (b < (i64)63 && ((i64)1 << b) < v)
                b = b + (i64)1;
            return b;
            }
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return (i64)64;
        i64 w = (i64)frBits(o.val().ty());
        if (w == (i64)0)
            w = (i64)64;
        if (isSigned)
            return w - (i64)1;
        Object* d = defOf.get((Hashable*)o.val());
        if (d == (Object*)0)
            return w;
        IRInsn* di = (IRInsn*)d;
        if (di.ops().count() == (u32)2)
            {
            IROperand* a = (IROperand*)di.ops().get((u32)0);
            IROperand* c = (IROperand*)di.ops().get((u32)1);
            i64 k = (i64)0;
            if (di.op().equals(String.withCString("And")) && self.frIntConst(c, defOf, &k) && k >= (i64)0)
                {
                i64 b = (i64)0;
                while (b < w && ((i64)1 << b) <= k)
                    b = b + (i64)1;
                return b < w ? b : w;
                }
            if (di.op().equals(String.withCString("LShr")) && self.frIntConst(c, defOf, &k) && k > (i64)0 && k < w)
                return w - k;
            }
        if (di.op().equals(String.withCString("ZExt")) && di.ops().count() >= (u32)1)
            {
            IROperand* s = (IROperand*)di.ops().get((u32)0);
            if (s.kind() == (u8)OPK_USE && s.val() != (IRValue*)0)
                {
                i64 sw = (i64)frBits(s.val().ty());
                if (sw > (i64)0 && sw < w)
                    return sw;
                }
            }
        return w;
        }

    // An integer constant, directly or through a Const and any ZExt/SExt/Trunc.
    final bool frIntConst(IROperand* o, Map* defOf, i64* out)
        {
        if (o.kind() == (u8)OPK_IMMI)
            {
            out[0] = o.imm();
            return true;
            }
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return false;
        IRValue* cur = o.val();
        for (u32 d = (u32)0; d < (u32)16; d = d + (u32)1)
            {
            Object* od = defOf.get((Hashable*)cur);
            if (od == (Object*)0)
                return false;
            IRInsn* di = (IRInsn*)od;
            if (di.ops().count() < (u32)1)
                return false;
            IROperand* k = (IROperand*)di.ops().get((u32)0);
            if (di.op().equals(String.withCString("Const")))
                {
                if (k.kind() != (u8)OPK_IMMI)
                    return false;
                out[0] = k.imm();
                return true;
                }
            if (!di.op().equals(String.withCString("ZExt")) && !di.op().equals(String.withCString("SExt"))
                && !di.op().equals(String.withCString("Trunc")))
                return false;
            if (k.kind() == (u8)OPK_IMMI)
                {
                out[0] = k.imm();
                return true;
                }
            if (k.kind() != (u8)OPK_USE || k.val() == (IRValue*)0)
                return false;
            cur = k.val();
            }
        return false;
        }

    // One instruction's bound from its operands'. True when it gained one.
    final bool frInsn(IRInsn* n, Map* defOf, Map* ex, Map* nn)
        {
        IRValue* r = n.res();
        if (r == (IRValue*)0 || !frIsFloat(r.ty()) || ex.get((Hashable*)r) != (Object*)0)
            return false;
        String* op = n.op();
        u32 nops = n.ops().count();
        i64 ea = (i64)0;
        i64 eb = (i64)0;
        bool na = false;
        bool nb = false;
        if (op.equals(String.withCString("Const")) && nops >= (u32)1)
            {
            IROperand* k = (IROperand*)n.ops().get((u32)0);
            if (k.kind() == (u8)OPK_IMMF && self.frConstBound(k.fpHex(), &ea, &na))
                return self.frSet(r, ea, na, ex, nn);
            return false;
            }
        if (op.equals(String.withCString("UIToFp")) && nops >= (u32)1)
            return self.frSet(r, self.frIntBound((IROperand*)n.ops().get((u32)0), defOf, false), true, ex, nn);
        if (op.equals(String.withCString("SIToFp")) && nops >= (u32)1)
            return self.frSet(r, self.frIntBound((IROperand*)n.ops().get((u32)0), defOf, true), false, ex, nn);
        if ((op.equals(String.withCString("Copy")) || op.equals(String.withCString("FpExt"))
             || op.equals(String.withCString("FpTrunc")) || op.equals(String.withCString("FNeg"))) && nops >= (u32)1)
            {
            if (!self.frGet((IROperand*)n.ops().get((u32)0), defOf, ex, nn, &ea, &na))
                return false;
            return self.frSet(r, ea, na && !op.equals(String.withCString("FNeg")), ex, nn);
            }
        if (op.equals(String.withCString("Select")) && nops == (u32)3)
            {
            if (!self.frGet((IROperand*)n.ops().get((u32)1), defOf, ex, nn, &ea, &na)
                || !self.frGet((IROperand*)n.ops().get((u32)2), defOf, ex, nn, &eb, &nb))
                return false;
            return self.frSet(r, ea > eb ? ea : eb, na && nb, ex, nn);
            }
        if (nops != (u32)2)
            return false;
        IROperand* a = (IROperand*)n.ops().get((u32)0);
        IROperand* b = (IROperand*)n.ops().get((u32)1);
        if (op.equals(String.withCString("FDiv")))
            {
            // Only by a nonzero normal constant: |b| >= 2^(e-1023).
            u64 bits = (u64)0;
            if (!self.frConstBits(b, defOf, &bits) || !self.frGet(a, defOf, ex, nn, &ea, &na))
                return false;
            u64 ef = (bits >> (u64)52) & (u64)$7FF;
            if (ef == (u64)0 || ef == (u64)$7FF)
                return false;
            return self.frSet(r, ea - ((i64)ef - (i64)1023), na && (bits >> (u64)63) == (u64)0, ex, nn);
            }
        if (!self.frGet(a, defOf, ex, nn, &ea, &na) || !self.frGet(b, defOf, ex, nn, &eb, &nb))
            return false;
        i64 mx = ea > eb ? ea : eb;
        if (op.equals(String.withCString("FMul")))
            return self.frSet(r, ea + eb, na && nb, ex, nn);
        if (op.equals(String.withCString("FAdd")))
            return self.frSet(r, mx + (i64)1, na && nb, ex, nn);
        if (op.equals(String.withCString("FSub")))
            return self.frSet(r, mx + (i64)1, false, ex, nn);
        return false;
        }

    // A phi's bound: every incoming known (the larger), or a loop phi that
    // scales by a constant once a trip of a counted loop.
    final bool frPhi(IRFunc* fn, IRBlock* H, IRInsn* p, Map* defOf, Map* ex, Map* nn)
        {
        IRValue* r = p.res();
        if (r == (IRValue*)0 || !frIsFloat(r.ty()) || ex.get((Hashable*)r) != (Object*)0)
            return false;
        u32 np = p.ops().count();
        i64 emax = (i64)-1100;
        bool allNn = true;
        bool all = np >= (u32)2;
        for (u32 k = (u32)0; all && k + (u32)1 < np; k = k + (u32)2)
            {
            i64 e = (i64)0;
            bool isNn = false;
            if (!self.frGet((IROperand*)p.ops().get(k + (u32)1), defOf, ex, nn, &e, &isNn))
                all = false;
            else
                {
                if (e > emax)
                    emax = e;
                allNn = allNn && isNn;
                }
            }
        if (all)
            return self.frSet(r, emax, allNn, ex, nn);
        if (np != (u32)4)
            return false;
        // init from one edge, next = p * c (or p + p) from a latch that
        // branches back to H on a counted compare.
        for (u32 side = (u32)0; side < (u32)2; side = side + (u32)1)
            {
            IROperand* lb = (IROperand*)p.ops().get(side * (u32)2);
            IROperand* lv = (IROperand*)p.ops().get(side * (u32)2 + (u32)1);
            IROperand* iv = (IROperand*)p.ops().get(((u32)1 - side) * (u32)2 + (u32)1);
            IROperand* ib = (IROperand*)p.ops().get(((u32)1 - side) * (u32)2);
            if (lb.kind() != (u8)OPK_BLOCK || lb.blk() == (IRBlock*)0 || ib.kind() != (u8)OPK_BLOCK)
                continue;
            if (lv.kind() != (u8)OPK_USE || lv.val() == (IRValue*)0)
                continue;
            i64 ei = (i64)0;
            bool ni = false;
            if (!self.frGet(iv, defOf, ex, nn, &ei, &ni))
                continue;
            Object* nd = defOf.get((Hashable*)lv.val());
            if (nd == (Object*)0)
                continue;
            IRInsn* nx = (IRInsn*)nd;
            if (nx.ops().count() != (u32)2)
                continue;
            IROperand* x0 = (IROperand*)nx.ops().get((u32)0);
            IROperand* x1 = (IROperand*)nx.ops().get((u32)1);
            bool s0 = x0.kind() == (u8)OPK_USE && x0.val() == r;
            bool s1 = x1.kind() == (u8)OPK_USE && x1.val() == r;
            i64 grow = (i64)0;
            bool keepNn = ni;
            if (nx.op().equals(String.withCString("FAdd")) && s0 && s1)
                grow = (i64)1;
            else if (nx.op().equals(String.withCString("FMul")) && (s0 || s1) && !(s0 && s1))
                {
                u64 bits = (u64)0;
                if (!self.frConstBits(s0 ? x1 : x0, defOf, &bits))
                    continue;
                u64 ef = (bits >> (u64)52) & (u64)$7FF;
                u64 mant = bits & (u64)$F_FFFF_FFFF_FFFF;
                if (ef == (u64)$7FF || (bits >> (u64)63) != (u64)0)
                    continue;
                i64 ce = ef == (u64)0 ? (i64)-1022 : (mant == (u64)0 ? (i64)ef - (i64)1023 : (i64)ef - (i64)1022);
                grow = ce > (i64)0 ? ce : (i64)0;
                }
            else
                continue;
            u32 trip = self.frTrip(H, lb.blk(), ib.blk(), defOf);
            if (trip == (u32)0)
                continue;
            return self.frSet(r, ei + (i64)(trip - (u32)1) * grow, keepNn, ex, nn);
            }
        return false;
        }

    // The most times H's body runs, from its counted latch L (entered from
    // block E): a header phi with a constant start and a constant positive
    // step, and L's CondBranch back to H on that counter (or its next value)
    // against a constant. 0 when it cannot be bounded (at most 256).
    final u32 frTrip(IRBlock* H, IRBlock* L, IRBlock* E, Map* defOf)
        {
        IRInsn* t = L.term();
        if (t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch")) || t.ops().count() != (u32)3)
            return (u32)0;
        IROperand* c = (IROperand*)t.ops().get((u32)0);
        IROperand* tt = (IROperand*)t.ops().get((u32)1);
        IROperand* tf = (IROperand*)t.ops().get((u32)2);
        bool toT = tt.kind() == (u8)OPK_BLOCK && tt.blk() == H;
        bool toF = tf.kind() == (u8)OPK_BLOCK && tf.blk() == H;
        if (toT == toF || c.kind() != (u8)OPK_USE || c.val() == (IRValue*)0)
            return (u32)0;
        Object* cd = defOf.get((Hashable*)c.val());
        if (cd == (Object*)0)
            return (u32)0;
        IRInsn* cmp = (IRInsn*)cd;
        if (!cmp.op().equals(String.withCString("ICmp")) || cmp.ops().count() != (u32)2 || cmp.pred() == (String*)0)
            return (u32)0;
        IROperand* ca = (IROperand*)cmp.ops().get((u32)0);
        i64 bound = (i64)0;
        if (ca.kind() != (u8)OPK_USE || ca.val() == (IRValue*)0 || !self.frIntConst((IROperand*)cmp.ops().get((u32)1), defOf, &bound))
            return (u32)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* q = (IRInsn*)H.phis().get(i);
            if (q.res() == (IRValue*)0 || frBits(q.res().ty()) == (u32)0 || q.ops().count() != (u32)4)
                continue;
            IROperand* qinit = (IROperand*)0;
            IROperand* qnext = (IROperand*)0;
            for (u32 k = (u32)0; k < (u32)4; k = k + (u32)2)
                {
                IROperand* qb = (IROperand*)q.ops().get(k);
                if (qb.kind() != (u8)OPK_BLOCK)
                    continue;
                if (qb.blk() == L)
                    qnext = (IROperand*)q.ops().get(k + (u32)1);
                else if (qb.blk() == E)
                    qinit = (IROperand*)q.ops().get(k + (u32)1);
                }
            i64 start = (i64)0;
            if (qinit == (IROperand*)0 || qnext == (IROperand*)0 || !self.frIntConst(qinit, defOf, &start))
                continue;
            if (qnext.kind() != (u8)OPK_USE || qnext.val() == (IRValue*)0)
                continue;
            Object* ad = defOf.get((Hashable*)qnext.val());
            if (ad == (Object*)0)
                continue;
            IRInsn* add = (IRInsn*)ad;
            if (!add.op().equals(String.withCString("Add")) || add.ops().count() != (u32)2)
                continue;
            IROperand* a0 = (IROperand*)add.ops().get((u32)0);
            IROperand* a1 = (IROperand*)add.ops().get((u32)1);
            i64 step = (i64)0;
            if (a0.kind() == (u8)OPK_USE && a0.val() == q.res() && self.frIntConst(a1, defOf, &step))
                {
                }
            else if (a1.kind() == (u8)OPK_USE && a1.val() == q.res() && self.frIntConst(a0, defOf, &step))
                {
                }
            else
                continue;
            if (step <= (i64)0)
                continue;
            bool onNext = ca.val() == qnext.val();
            if (!onNext && ca.val() != q.res())
                continue;
            // The body runs for the counter's values start, start+step, ...
            // and after each L tests the counter (or its next value) and goes
            // back to H while the compare says so.
            u32 runs = (u32)1;
            i64 v = start;
            while (runs <= (u32)256)
                {
                i64 tested = onNext ? v + step : v;
                bool cnd = frICmp(cmp.pred(), tested, bound, frBits(q.res().ty()));
                if (cnd != toT)
                    return runs;
                v = v + step;
                runs = runs + (u32)1;
                }
            return (u32)0;
            }
        return (u32)0;
        }

    // An integer compare at a width, unsigned or signed by its predicate.
    static bool frICmp(String* p, i64 a, i64 b, u32 w)
        {
        u64 mask = w >= (u32)64 ? (u64)$FFFF_FFFF_FFFF_FFFF : (((u64)1 << (u64)w) - (u64)1);
        u64 ua = (u64)a & mask;
        u64 ub = (u64)b & mask;
        i64 sa = a;
        i64 sb = b;
        if (w < (u32)64)
            {
            u64 sbit = (u64)1 << (u64)(w - (u32)1);
            sa = (i64)((ua ^ sbit) - sbit);
            sb = (i64)((ub ^ sbit) - sbit);
            }
        if (p.equals(String.withCString("EQ"))) return ua == ub;
        if (p.equals(String.withCString("NE"))) return ua != ub;
        if (p.equals(String.withCString("ULT"))) return ua < ub;
        if (p.equals(String.withCString("ULE"))) return ua <= ub;
        if (p.equals(String.withCString("UGT"))) return ua > ub;
        if (p.equals(String.withCString("UGE"))) return ua >= ub;
        if (p.equals(String.withCString("SLT"))) return sa < sb;
        if (p.equals(String.withCString("SLE"))) return sa <= sb;
        if (p.equals(String.withCString("SGT"))) return sa > sb;
        if (p.equals(String.withCString("SGE"))) return sa >= sb;
        return false;
        }

    }
