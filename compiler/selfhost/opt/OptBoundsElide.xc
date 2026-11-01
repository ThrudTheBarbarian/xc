// OptBoundsElide.xc — the BoundsElide pass, ported from src/xtc/ir/XTIROptBoundsElide.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptDeadCode>
#import <OptReassociate>
#import <OptRedundantLoadCSE>
#import <OptVectorizeParts>

    class Opt (BoundsElide)
    {

    final void boundsElide(IRModule* m)
        {
        String* chk = String.withCString("_xt_check_bounds_n");
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            _beDef = fn.blocks().count() > (u32)0 ? self.defMap(fn) : (Map*)0;
            bool any = false;
            for (u32 b = (u32)0; b < fn.blocks().count() && !any; b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 i = (u32)0; i < bb.insns().count() && !any; i = i + (u32)1)
                    any = beIsCheck((IRInsn*)bb.insns().get(i), chk) || beIsHeapCheck((IRInsn*)bb.insns().get(i))
                       || beWideIndex((IRInsn*)bb.insns().get(i)) != (IRValue*)0;
                }
            if (!any || fn.blocks().count() == (u32)0)
                continue;
            Map* idom = beDominators(fn);
            Map* blockFacts = beGuardFacts(fn);
            bool removed = false;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* X = (IRBlock*)fn.blocks().get(b);
                _beFacts = new Array();
                IRBlock* d = X;
                for (u32 guard = (u32)0; d != (IRBlock*)0 && guard < (u32)4096; guard = guard + (u32)1)
                    {
                    Array* fs = (Array*)blockFacts.get((Hashable*)d);
                    for (u32 k = (u32)0; fs != (Array*)0 && k < fs.count(); k = k + (u32)1)
                        _beFacts.add(fs.get(k));
                    IRBlock* up = (IRBlock*)idom.get((Hashable*)d);
                    d = up == d ? (IRBlock*)0 : up;
                    }
                // A subscript widened from 32 bits (C's `a[i]` reads `zext i`
                // into an i64 index) uses the 32-bit value itself when that is
                // proved inside [0, 2^31): the same element, and the iv-indexed
                // shape the vectoriser takes. A literal start gave it this
                // already (mem2reg); a runtime one now does too.
                for (u32 k = (u32)0; k < X.insns().count(); k = k + (u32)1)
                    {
                    IRInsn* ea = (IRInsn*)X.insns().get(k);
                    IRValue* narrow = beWideIndex(ea);
                    i64 wlo = (i64)0;
                    i64 whi = (i64)0;
                    _beVisit = new Map();
                    if (narrow != (IRValue*)0 && beRange(IROperand.useVal(narrow), &wlo, &whi, (u32)0)
                        && wlo >= (i64)0 && whi <= (i64)$7FFFFFFF)
                        ea.ops().set((u32)1, (Object*)IROperand.useVal(narrow));
                    }
                u32 i = (u32)0;
                while (i < X.insns().count())
                    {
                    IRInsn* n = (IRInsn*)X.insns().get(i);
                    i64 count = (i64)0;
                    i64 lo = (i64)0;
                    i64 hi = (i64)0;
                    _beVisit = new Map();
                    // A fixed-size array's check carries its count; a heap
                    // pointer's has one when the pointer is `new T[c]`'s
                    // own result, c a constant.
                    bool fixed = beIsCheck(n, chk);
                    bool known = fixed ? self.vecConstWide((IROperand*)n.ops().get((u32)3), _beDef, &count)
                                       : beIsHeapCheck(n) && beNewCount((IROperand*)n.ops().get((u32)1), &count);
                    if (known && beRange((IROperand*)n.ops().get((u32)2), &lo, &hi, (u32)0)
                        && lo >= (i64)0 && hi < count && n.memRes() != (IRValue*)0)
                        {
                        // The call's memory goes to whatever it came from.
                        self.rewriteUsesTo(fn, n.memRes(), (IROperand*)n.ops().get(n.ops().count() - (u32)1));
                        X.insns().removeAt(i);
                        removed = true;
                        continue;
                        }
                    i = i + (u32)1;
                    }
                }
            _beDef = (Map*)0;
            _beFacts = (Array*)0;
            _beVisit = (Map*)0;
            // An `if` body that held a check was a call, so if-conversion left
            // it a branch: with the checks gone it may be a select now. Only
            // the functions checks came out of, so an unchecked build is
            // untouched. As the reference.
            if (removed && _profile.ifConvert() && !Opt.ppEnvSet("XTIC_OFF"))
                {
                // What the checks leave (their site strings and counts) goes,
                // then the arms' loads, as before the first if-conversion: the
                // checks kept each arm's `a[i]` its own load, which an arm may
                // not speculate.
                self.deadCodeInFunc(fn);
                _cseCrossBlock = _profile.hoistLocalAddr();
                self.cseInFunc(fn);
                _cseCrossBlock = false;
                for (u32 iter = (u32)0; iter < (u32)4096; iter = iter + (u32)1)
                    if (!self.ifConvertOnce(fn))
                        break;
                }
            }
        }

    static bool beIsCheck(IRInsn* n, String* chk)
        {
        return n.op().equals(String.withCString("Call")) && n.ops().count() == (u32)6
            && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_SYM
            && ((IROperand*)n.ops().get((u32)0)).name().equals(chk);
        }

    // `ElementAddr base, ZExt(x)` with x a 32-bit integer: x, else 0.
    final IRValue* beWideIndex(IRInsn* n)
        {
        if (!n.op().equals(String.withCString("ElementAddr")) || n.ops().count() < (u32)2 || _beDef == (Map*)0)
            return (IRValue*)0;
        IROperand* ix = (IROperand*)n.ops().get((u32)1);
        if (ix.kind() != (u8)OPK_USE)
            return (IRValue*)0;
        IRInsn* d = (IRInsn*)_beDef.get((Hashable*)ix.val());
        if (d == (IRInsn*)0 || !d.op().equals(String.withCString("ZExt")) || d.ops().count() < (u32)1)
            return (IRValue*)0;
        IROperand* a = (IROperand*)d.ops().get((u32)0);
        if (a.kind() != (u8)OPK_USE || a.val() == (IRValue*)0)
            return (IRValue*)0;
        String* t = a.val().ty();
        if (t == (String*)0 || !(t.equals(String.withCString("I32")) || t.equals(String.withCString("U32"))))
            return (IRValue*)0;
        return a.val();
        }

    static bool beIsHeapCheck(IRInsn* n)
        {
        return n.op().equals(String.withCString("Call")) && n.ops().count() == (u32)5
            && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_SYM
            && ((IROperand*)n.ops().get((u32)0)).name().equals(String.withCString("_xt_check_bounds"));
        }

    // The element count of the `new T[c]` that made p, when c is a constant:
    // p is the result of a call to an `_xtc_new_<T>` allocator, whose one
    // argument is the count.
    final bool beNewCount(IROperand* p, i64* count)
        {
        if (p.kind() != (u8)OPK_USE)
            return false;
        IRInsn* d = (IRInsn*)_beDef.get((Hashable*)p.val());
        if (d == (IRInsn*)0 || !d.op().equals(String.withCString("Call")) || d.ops().count() != (u32)3
            || ((IROperand*)d.ops().get((u32)0)).kind() != (u8)OPK_SYM
            || !((IROperand*)d.ops().get((u32)0)).name().hasPrefix(String.withCString("_xtc_new_")))
            return false;
        return self.vecConstWide((IROperand*)d.ops().get((u32)1), _beDef, count) && count[0] > (i64)0;
        }

    // A type's whole range, false for anything but an integer. U64's top half
    // is left out, so every bound fits an i64 with room to add.
    static bool beTypeRange(String* ty, i64* lo, i64* hi)
        {
        if (ty == (String*)0)
            return false;
        i64 w = (i64)0;
        bool isSigned = false;
        if (ty.equals(String.withCString("U8"))) w = (i64)8;
        else if (ty.equals(String.withCString("U16"))) w = (i64)16;
        else if (ty.equals(String.withCString("U32"))) w = (i64)32;
        else if (ty.equals(String.withCString("U64"))) w = (i64)62;
        else if (ty.equals(String.withCString("I8"))) { w = (i64)8; isSigned = true; }
        else if (ty.equals(String.withCString("I16"))) { w = (i64)16; isSigned = true; }
        else if (ty.equals(String.withCString("I32"))) { w = (i64)32; isSigned = true; }
        else if (ty.equals(String.withCString("I64"))) { w = (i64)62; isSigned = true; }
        else
            return false;
        if (isSigned)
            {
            lo[0] = (i64)0 - ((i64)1 << (w - (i64)1));
            hi[0] = ((i64)1 << (w - (i64)1)) - (i64)1;
            }
        else
            {
            lo[0] = (i64)0;
            hi[0] = ((i64)1 << w) - (i64)1;
            }
        return true;
        }

    static bool beUnsigned(String* ty)
        {
        return ty != (String*)0 && ty.byteLength() > (u32)0 && ty.byteAt((u32)0) == (u8)'U';
        }

    // op's range in the check's block: its type's, narrowed by its definition
    // and by the facts that hold there.
    final bool beRange(IROperand* op, i64* lo, i64* hi, u32 depth)
        {
        if (op.kind() == (u8)OPK_IMMI)
            {
            lo[0] = op.imm();
            hi[0] = op.imm();
            return true;
            }
        if (op.kind() != (u8)OPK_USE || op.val() == (IRValue*)0 || depth > (u32)24)
            return false;
        IRValue* v = op.val();
        i64 tlo = (i64)0;
        i64 thi = (i64)0;
        if (!beTypeRange(v.ty(), &tlo, &thi))
            return false;
        i64 rlo = tlo;
        i64 rhi = thi;
        IRInsn* def = (IRInsn*)_beDef.get((Hashable*)v);
        if (def != (IRInsn*)0)
            {
            i64 dlo = (i64)0;
            i64 dhi = (i64)0;
            if (beDefRange(def, v, &dlo, &dhi, depth) && dlo >= tlo && dhi <= thi)
                {
                rlo = dlo;
                rhi = dhi;
                }
            }
        for (u32 k = (u32)0; k < _beFacts.count(); k = k + (u32)1)
            {
            BeFact* fa = (BeFact*)_beFacts.get(k);
            if (fa._v != v)
                continue;
            if (fa._lo > rlo)
                rlo = fa._lo;
            if (fa._hi < rhi)
                rhi = fa._hi;
            }
        lo[0] = rlo;
        hi[0] = rhi;
        return rlo <= rhi;
        }

    // What a definition says of its value, before the facts.
    final bool beDefRange(IRInsn* def, IRValue* v, i64* lo, i64* hi, u32 depth)
        {
        String* o = def.op();
        Array* ops = def.ops();
        i64 alo = (i64)0;
        i64 ahi = (i64)0;
        i64 blo = (i64)0;
        i64 bhi = (i64)0;
        i64 big = (i64)1 << (i64)61;
        if (o.equals(String.withCString("Const")))
            {
            if (ops.count() < (u32)1 || ((IROperand*)ops.get((u32)0)).kind() != (u8)OPK_IMMI)
                return false;
            lo[0] = ((IROperand*)ops.get((u32)0)).imm();
            hi[0] = lo[0];
            return true;
            }
        if (o.equals(String.withCString("Phi")))
            return bePhiRange(def, v, lo, hi, depth);
        if (ops.count() < (u32)1 || !beRange((IROperand*)ops.get((u32)0), &alo, &ahi, depth + (u32)1))
            return false;
        if (o.equals(String.withCString("ZExt")))
            {
            if (alo < (i64)0)
                return false;
            lo[0] = alo;
            hi[0] = ahi;
            return true;
            }
        if (o.equals(String.withCString("SExt")) || o.equals(String.withCString("Trunc")))
            {
            lo[0] = alo;
            hi[0] = ahi;
            return true;
            }
        if (ops.count() < (u32)2 || !beRange((IROperand*)ops.get((u32)1), &blo, &bhi, depth + (u32)1))
            return false;
        if (alo < (i64)0 - big || ahi > big || blo < (i64)0 - big || bhi > big)
            return false;
        if (o.equals(String.withCString("Add")))
            {
            lo[0] = alo + blo;
            hi[0] = ahi + bhi;
            return true;
            }
        if (o.equals(String.withCString("Sub")))
            {
            lo[0] = alo - bhi;
            hi[0] = ahi - blo;
            return true;
            }
        i64 lim = (i64)1 << (i64)30;
        if (o.equals(String.withCString("Mul")))
            {
            if (alo < (i64)0 || blo < (i64)0 || ahi > lim || bhi > lim)
                return false;
            lo[0] = alo * blo;
            hi[0] = ahi * bhi;
            return true;
            }
        if (o.equals(String.withCString("Shl")))
            {
            if (alo < (i64)0 || blo != bhi || blo < (i64)0 || blo > (i64)30 || ahi > lim)
                return false;
            lo[0] = alo << blo;
            hi[0] = ahi << blo;
            return true;
            }
        if (o.equals(String.withCString("LShr")))
            {
            if (alo < (i64)0 || blo != bhi || blo < (i64)0 || blo > (i64)62)
                return false;
            lo[0] = alo >> blo;
            hi[0] = ahi >> blo;
            return true;
            }
        if (o.equals(String.withCString("And")))
            {
            // At most the smaller of the two non-negative ones.
            if (alo >= (i64)0 && blo >= (i64)0)
                hi[0] = ahi < bhi ? ahi : bhi;
            else if (alo >= (i64)0)
                hi[0] = ahi;
            else if (blo >= (i64)0)
                hi[0] = bhi;
            else
                return false;
            lo[0] = (i64)0;
            return true;
            }
        if (o.equals(String.withCString("URem")))
            {
            if (blo != bhi || blo <= (i64)0)
                return false;
            lo[0] = (i64)0;
            hi[0] = blo - (i64)1;
            if (alo >= (i64)0 && ahi < hi[0])
                hi[0] = ahi;
            return true;
            }
        if (o.equals(String.withCString("UDiv")))
            {
            if (alo < (i64)0 || blo != bhi || blo <= (i64)0)
                return false;
            lo[0] = alo / blo;
            hi[0] = ahi / blo;
            return true;
            }
        return false;
        }

    // A phi: the range of its entries, stretched toward the type's end its
    // back edges move it (`v + c` up, `v - c` down); a cycle through it
    // that is neither reads as the type's range.
    final bool bePhiRange(IRInsn* def, IRValue* v, i64* lo, i64* hi, u32 depth)
        {
        if (_beVisit.get((Hashable*)v) != (Object*)0)
            return false;
        _beVisit.set((Hashable*)v, (Object*)v);
        i64 tlo = (i64)0;
        i64 thi = (i64)0;
        beTypeRange(v.ty(), &tlo, &thi);
        bool up = false;
        bool down = false;
        bool seen = false;
        i64 elo = (i64)0;
        i64 ehi = (i64)0;
        bool ok = true;
        for (u32 k = (u32)1; k < def.ops().count() && ok; k = k + (u32)2)
            {
            IROperand* inc = (IROperand*)def.ops().get(k);
            if (inc.kind() == (u8)OPK_USE && inc.val() == v)
                continue;
            i64 step = (i64)0;
            if (beStepOf(inc, v, &step))
                {
                if (step > (i64)0)
                    up = true;
                else if (step < (i64)0)
                    down = true;
                continue;
                }
            i64 ilo = (i64)0;
            i64 ihi = (i64)0;
            if (!beRange(inc, &ilo, &ihi, depth + (u32)1))
                {
                ok = false;
                break;
                }
            if (!seen || ilo < elo)
                elo = ilo;
            if (!seen || ihi > ehi)
                ehi = ihi;
            seen = true;
            }
        _beVisit.remove((Hashable*)v);
        if (!ok || !seen || (up && down))
            return false;
        lo[0] = down ? tlo : elo;
        hi[0] = up ? thi : ehi;
        return true;
        }

    // `v + c` or `v - c` (c a constant): the step, signed.
    final bool beStepOf(IROperand* inc, IRValue* v, i64* step)
        {
        if (inc.kind() != (u8)OPK_USE)
            return false;
        IRInsn* d = (IRInsn*)_beDef.get((Hashable*)inc.val());
        if (d == (IRInsn*)0 || d.ops().count() < (u32)2)
            return false;
        bool add = d.op().equals(String.withCString("Add"));
        bool sub = d.op().equals(String.withCString("Sub"));
        if (!add && !sub)
            return false;
        IROperand* a = (IROperand*)d.ops().get((u32)0);
        IROperand* b = (IROperand*)d.ops().get((u32)1);
        i64 c = (i64)0;
        if (a.kind() == (u8)OPK_USE && a.val() == v && self.vecConstWide(b, _beDef, &c))
            {
            step[0] = add ? c : (i64)0 - c;
            return true;
            }
        if (add && b.kind() == (u8)OPK_USE && b.val() == v && self.vecConstWide(a, _beDef, &c))
            {
            step[0] = c;
            return true;
            }
        return false;
        }

    // Each block a guard's edge is the only way into: the facts that edge
    // gives (block -> BeFact@).
    final Map* beGuardFacts(IRFunc* fn)
        {
        Map* preds = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRInsn* t = ((IRBlock*)fn.blocks().get(b)).term();
            for (u32 k = (u32)0; t != (IRInsn*)0 && k < t.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                    continue;
                Number* c = (Number*)preds.get((Hashable*)o.blk());
                preds.set((Hashable*)o.blk(), (Object*)Number.withU32(c == (Number*)0 ? (u32)1 : c.asU32() + (u32)1));
                }
            }
        Map* out = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* H = (IRBlock*)fn.blocks().get(b);
            IRInsn* t = H.term();
            if (t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch")) || t.ops().count() < (u32)3)
                continue;
            IROperand* c = (IROperand*)t.ops().get((u32)0);
            if (c.kind() != (u8)OPK_USE)
                continue;
            IRInsn* cmp = (IRInsn*)_beDef.get((Hashable*)c.val());
            if (cmp == (IRInsn*)0 || !cmp.op().equals(String.withCString("ICmp")) || cmp.pred() == (String*)0 || cmp.ops().count() < (u32)2)
                continue;
            for (u32 e = (u32)1; e <= (u32)2; e = e + (u32)1)
                {
                IRBlock* T = ((IROperand*)t.ops().get(e)).blk();
                Number* np = T == (IRBlock*)0 ? (Number*)0 : (Number*)preds.get((Hashable*)T);
                if (T == (IRBlock*)0 || T == H || np == (Number*)0 || np.asU32() != (u32)1)
                    continue;
                BeFact* fa = beFactOf(cmp, e == (u32)1);
                if (fa == (BeFact*)0)
                    continue;
                Array* fs = (Array*)out.get((Hashable*)T);
                if (fs == (Array*)0)
                    {
                    fs = new Array();
                    out.set((Hashable*)T, (Object*)fs);
                    }
                fs.add((Object*)fa);
                }
            }
        return out;
        }

    // `ICmp pred a, b` taken (or not): what it says of the value against the
    // constant, or 0.
    final BeFact* beFactOf(IRInsn* cmp, bool taken)
        {
        IROperand* a = (IROperand*)cmp.ops().get((u32)0);
        IROperand* b = (IROperand*)cmp.ops().get((u32)1);
        String* p = cmp.pred();
        i64 c = (i64)0;
        IRValue* v = (IRValue*)0;
        if (a.kind() == (u8)OPK_USE && self.vecConstWide(b, _beDef, &c))
            v = a.val();
        else if (b.kind() == (u8)OPK_USE && self.vecConstWide(a, _beDef, &c))
            {
            v = b.val();
            p = beSwapPred(p);
            }
        // `a <u min(x, K)` taken: a is below K as surely as against K itself
        // (the outliner clamps a chunk's end to its loop's bound this way,
        // 2026-10-25). As the reference.
        else if (taken && a.kind() == (u8)OPK_USE && p != (String*)0
                 && (p.equals(String.withCString("ULT")) || p.equals(String.withCString("ULE")))
                 && beMinConst(b, &c))
            v = a.val();
        if (v == (IRValue*)0 || p == (String*)0)
            return (BeFact*)0;
        if (!taken)
            p = beNotPred(p);
        if (p == (String*)0)
            return (BeFact*)0;
        i64 tlo = (i64)0;
        i64 thi = (i64)0;
        if (!beTypeRange(v.ty(), &tlo, &thi))
            return (BeFact*)0;
        bool uns = beUnsigned(v.ty());
        BeFact* fa = new BeFact();
        fa._v = v;
        fa._lo = tlo;
        fa._hi = thi;
        // An unsigned `<` against a non-negative constant bounds the value on
        // both sides, as its bits read unsigned, whatever its type.
        if ((p.equals(String.withCString("ULT")) || p.equals(String.withCString("ULE"))) && c >= (i64)0)
            {
            fa._lo = (i64)0;
            fa._hi = p.equals(String.withCString("ULT")) ? c - (i64)1 : c;
            return fa;
            }
        if ((p.equals(String.withCString("UGT")) || p.equals(String.withCString("UGE"))) && uns && c >= (i64)0)
            {
            fa._lo = p.equals(String.withCString("UGT")) ? c + (i64)1 : c;
            return fa;
            }
        if (!uns && (p.equals(String.withCString("SLT")) || p.equals(String.withCString("SLE"))))
            {
            fa._hi = p.equals(String.withCString("SLT")) ? c - (i64)1 : c;
            return fa;
            }
        if (!uns && (p.equals(String.withCString("SGT")) || p.equals(String.withCString("SGE"))))
            {
            fa._lo = p.equals(String.withCString("SGT")) ? c + (i64)1 : c;
            return fa;
            }
        if (p.equals(String.withCString("EQ")))
            {
            fa._lo = c;
            fa._hi = c;
            return fa;
            }
        return (BeFact*)0;
        }

    // `Select (ICmp ULT x, K), x, K`, the unsigned min of x and a constant
    // K >= 0: K in *k. As the reference's minConstOf.
    final bool beMinConst(IROperand* o, i64* k)
        {
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return false;
        IRInsn* sel = (IRInsn*)_beDef.get((Hashable*)o.val());
        if (sel == (IRInsn*)0 || !sel.op().equals(String.withCString("Select")) || sel.ops().count() != (u32)3)
            return false;
        IROperand* sc = (IROperand*)sel.ops().get((u32)0);
        IROperand* st = (IROperand*)sel.ops().get((u32)1);
        IROperand* sf = (IROperand*)sel.ops().get((u32)2);
        if (sc.kind() != (u8)OPK_USE || st.kind() != (u8)OPK_USE)
            return false;
        IRInsn* cmp = (IRInsn*)_beDef.get((Hashable*)sc.val());
        if (cmp == (IRInsn*)0 || !cmp.op().equals(String.withCString("ICmp")) || cmp.pred() == (String*)0
            || !cmp.pred().equals(String.withCString("ULT")) || cmp.ops().count() < (u32)2)
            return false;
        IROperand* cx = (IROperand*)cmp.ops().get((u32)0);
        i64 kc = (i64)0;
        i64 kf = (i64)0;
        if (cx.kind() != (u8)OPK_USE || cx.val() != st.val()
            || !self.vecConstWide((IROperand*)cmp.ops().get((u32)1), _beDef, &kc) || !self.vecConstWide(sf, _beDef, &kf)
            || kc != kf || kc < (i64)0)
            return false;
        k[0] = kc;
        return true;
        }

    static String* beSwapPred(String* p)
        {
        if (p == (String*)0) return (String*)0;
        if (p.equals(String.withCString("ULT"))) return String.withCString("UGT");
        if (p.equals(String.withCString("UGT"))) return String.withCString("ULT");
        if (p.equals(String.withCString("ULE"))) return String.withCString("UGE");
        if (p.equals(String.withCString("UGE"))) return String.withCString("ULE");
        if (p.equals(String.withCString("SLT"))) return String.withCString("SGT");
        if (p.equals(String.withCString("SGT"))) return String.withCString("SLT");
        if (p.equals(String.withCString("SLE"))) return String.withCString("SGE");
        if (p.equals(String.withCString("SGE"))) return String.withCString("SLE");
        if (p.equals(String.withCString("EQ"))) return p;
        return (String*)0;
        }

    static String* beNotPred(String* p)
        {
        if (p.equals(String.withCString("ULT"))) return String.withCString("UGE");
        if (p.equals(String.withCString("UGE"))) return String.withCString("ULT");
        if (p.equals(String.withCString("ULE"))) return String.withCString("UGT");
        if (p.equals(String.withCString("UGT"))) return String.withCString("ULE");
        if (p.equals(String.withCString("SLT"))) return String.withCString("SGE");
        if (p.equals(String.withCString("SGE"))) return String.withCString("SLT");
        if (p.equals(String.withCString("SLE"))) return String.withCString("SGT");
        if (p.equals(String.withCString("SGT"))) return String.withCString("SLE");
        return (String*)0;
        }

    // Immediate dominators (block -> block; the entry is its own), by the
    // iterative intersection over a reverse postorder.
    final Map* beDominators(IRFunc* fn)
        {
        IRBlock* entry = (IRBlock*)fn.blocks().get((u32)0);
        Array* order = new Array();     // postorder
        Map* seen = new Map();
        Array* stack = new Array();
        Array* next = new Array();      // Number@: the successor index to try next
        stack.add((Object*)entry);
        next.add((Object*)Number.withU32((u32)0));
        seen.set((Hashable*)entry, (Object*)entry);
        while (stack.count() > (u32)0)
            {
            IRBlock* top = (IRBlock*)stack.get(stack.count() - (u32)1);
            u32 k = ((Number*)next.get(next.count() - (u32)1)).asU32();
            IRInsn* t = top.term();
            bool pushed = false;
            while (t != (IRInsn*)0 && k < t.ops().count() && !pushed)
                {
                IROperand* o = (IROperand*)t.ops().get(k);
                k = k + (u32)1;
                if (o.kind() == (u8)OPK_BLOCK && o.blk() != (IRBlock*)0 && seen.get((Hashable*)o.blk()) == (Object*)0)
                    {
                    next.set(next.count() - (u32)1, (Object*)Number.withU32(k));
                    seen.set((Hashable*)o.blk(), (Object*)o.blk());
                    stack.add((Object*)o.blk());
                    next.add((Object*)Number.withU32((u32)0));
                    pushed = true;
                    }
                }
            if (!pushed)
                {
                order.add((Object*)top);
                stack.removeAt(stack.count() - (u32)1);
                next.removeAt(next.count() - (u32)1);
                }
            }
        Map* po = new Map();            // block -> its postorder number
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            po.set((Hashable*)order.get(i), (Object*)Number.withU32(i));
        Map* preds = new Map();         // block -> Array of predecessors
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            IRBlock* bb = (IRBlock*)order.get(i);
            IRInsn* t = bb.term();
            for (u32 k = (u32)0; t != (IRInsn*)0 && k < t.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                    continue;
                Array* ps = (Array*)preds.get((Hashable*)o.blk());
                if (ps == (Array*)0)
                    {
                    ps = new Array();
                    preds.set((Hashable*)o.blk(), (Object*)ps);
                    }
                ps.add((Object*)bb);
                }
            }
        Map* idom = new Map();
        idom.set((Hashable*)entry, (Object*)entry);
        bool changed = true;
        while (changed)
            {
            changed = false;
            for (u32 r = order.count(); r > (u32)0; r = r - (u32)1)
                {
                IRBlock* bb = (IRBlock*)order.get(r - (u32)1);
                if (bb == entry)
                    continue;
                Array* ps = (Array*)preds.get((Hashable*)bb);
                IRBlock* nd = (IRBlock*)0;
                for (u32 k = (u32)0; ps != (Array*)0 && k < ps.count(); k = k + (u32)1)
                    {
                    IRBlock* p = (IRBlock*)ps.get(k);
                    if (idom.get((Hashable*)p) == (Object*)0)
                        continue;
                    nd = nd == (IRBlock*)0 ? p : beIntersect(p, nd, idom, po);
                    }
                if (nd != (IRBlock*)0 && (IRBlock*)idom.get((Hashable*)bb) != nd)
                    {
                    idom.set((Hashable*)bb, (Object*)nd);
                    changed = true;
                    }
                }
            }
        return idom;
        }

    static IRBlock* beIntersect(IRBlock* a, IRBlock* b, Map* idom, Map* po)
        {
        for (u32 guard = (u32)0; a != b && guard < (u32)100000; guard = guard + (u32)1)
            {
            while (((Number*)po.get((Hashable*)a)).asU32() < ((Number*)po.get((Hashable*)b)).asU32())
                a = (IRBlock*)idom.get((Hashable*)a);
            while (((Number*)po.get((Hashable*)b)).asU32() < ((Number*)po.get((Hashable*)a)).asU32())
                b = (IRBlock*)idom.get((Hashable*)b);
            }
        return a;
        }
    }
