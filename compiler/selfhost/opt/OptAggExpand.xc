// OptAggExpand.xc — the AggExpand pass, ported from src/xtc/ir/XTIROptAggExpand.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (AggExpand)
    {
    // ── if-convert ───────────────────────────────────────────────────────
    //
    // A diamond whose one arm is PURE — `cond ? f(x) : x` with no memory, no
    // call and nothing that can trap — becomes straight-line code: the arm's
    // instructions are hoisted (they now run unconditionally, which is sound
    // because none of them can be observed) and the join's phis become Selects.
    //
    // One diamond at a time, re-recognised from the live CFG after each
    // transform, because applying one removes a block and rewrites phis.

    // ── agg-expand ───────────────────────────────────────────────────────
    //
    // Turns whole-aggregate memory traffic into per-field traffic. Two shapes:
    //
    //   * `v:Agg = Load p; a = AddrOf v; FieldAddr a, #k` — the SNAPSHOT an
    //     inlined by-value parameter leaves behind — becomes `FieldAddr p, #k`,
    //     reading the field where it already lives instead of through a copy.
    //     There can be several AddrOfs of one snapshot.
    //   * `v:Agg = Load src; ...; Store dst, v` — a struct copy — becomes one
    //     Load/Store pair per field. The field loads replace the aggregate load
    //     WHERE IT STANDS and the field stores replace the store where IT
    //     stands, so every read and write happens exactly where it did before
    //     and no alias reasoning is needed for this half.
    //
    // Neither is faster by itself. What they buy is that the fields become
    // ordinary scalar memory operations, which store-to-load forwarding can see
    // through — which is where struct_copy's win actually comes from.

    // Splitting a copy of a large struct is worse than the block move the back
    // end would emit; the point here is the two- or three-field struct a caller
    // passes by value and a callee rebuilds.
    final u32 aeMaxFields(void)
        {
        return (u32)4;
        }

    final void aggExpand(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            u32 round = (u32)0;
            while (round < (u32)16 && aggExpandOnce(m, fn))
                round = round + (u32)1;
            }
        }

    final bool aeIsAgg(String* t)
        {
        return t != (String*)0 && t.byteLength() > (u32)4
               && t.byteAt((u32)0) == (u8)'A' && t.byteAt((u32)1) == (u8)'g'
               && t.byteAt((u32)2) == (u8)'g' && t.byteAt((u32)3) == (u8)'(';
        }

    // The pinned local a pointer ultimately names, or 0. Walks FieldAddr and
    // ElementAddr back to the AddrOf that started the chain.
    final IRValue* aeBaseLocal(IRValue* v, Map* defOf)
        {
        IRValue* cur = v;
        for (u32 hop = (u32)0; hop < (u32)8; hop = hop + (u32)1)
            {
            Object* dd = defOf.get((Hashable*)cur);
            if (dd == (Object*)0)
                return (IRValue*)0;
            IRInsn* d = (IRInsn*)dd;
            if (d.ops().count() < (u32)1)
                return (IRValue*)0;
            IROperand* a0 = (IROperand*)d.ops().get((u32)0);
            if (a0.kind() != (u8)OPK_USE)
                return (IRValue*)0;
            if (d.op().equals(String.withCString("AddrOf")))
                return a0.val();
            if (!d.op().equals(String.withCString("FieldAddr"))
                && !d.op().equals(String.withCString("ElementAddr")))
                return (IRValue*)0;
            cur = a0.val();
            }
        return (IRValue*)0;
        }

    final bool aeIsPinned(IRFunc* fn, IRValue* v)
        {
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1)
            if (((IRPinned*)fn.pinned().get(i)).val() == v)
                return true;
        return false;
        }

    // Could a store through `sp` disturb a read through `lp`? Distinct PINNED
    // LOCALS are distinct storage, which is the only thing that needs proving
    // here — the snapshot's own fields are read while the fields of ANOTHER
    // local are being written, and without this that would block the fold.
    final bool aeMayAlias(IRFunc* fn, IRValue* sp, IRValue* lp, Map* defOf)
        {
        if (sp == lp)
            return true;
        IRValue* a = aeBaseLocal(sp, defOf);
        IRValue* b = aeBaseLocal(lp, defOf);
        if (a == (IRValue*)0 || b == (IRValue*)0)
            return true;
        if (!aeIsPinned(fn, a) || !aeIsPinned(fn, b))
            return true;
        return a == b;
        }

    final u32 aeIndexOf(Array* insns, IRInsn* n)
        {
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            if ((IRInsn*)insns.get(i) == n)
                return i;
        return insns.count();
        }

    // Point every use of `from` at `to`, across the whole function.
    final void aeReplaceUses(IRFunc* fn, IRValue* from, IROperand* to)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            aeReplaceIn(bb.phis(), from, to);
            aeReplaceIn(bb.insns(), from, to);
            if (bb.term() != (IRInsn*)0)
                aeReplaceOne(bb.term(), from, to);
            }
        }

    final void aeReplaceIn(Array* insns, IRValue* from, IROperand* to)
        {
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            aeReplaceOne((IRInsn*)insns.get(i), from, to);
        }

    final void aeReplaceOne(IRInsn* n, IRValue* from, IROperand* to)
        {
        for (u32 q = (u32)0; q < n.ops().count(); q = q + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(q);
            if (o.kind() == (u8)OPK_USE && o.val() == from)
                n.ops().set(q, (Object*)to);
            }
        }

    final Map* aeDefMap(IRFunc* fn)
        {
        Map* defOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            aeDefsIn(bb.phis(), defOf);
            aeDefsIn(bb.insns(), defOf);
            if (bb.term() != (IRInsn*)0 && bb.term().res() != (IRValue*)0)
                defOf.set((Hashable*)bb.term().res(), (Object*)bb.term());
            }
        return defOf;
        }

    final void aeDefsIn(Array* insns, Map* defOf)
        {
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)insns.get(i);
            if (n.res() != (IRValue*)0)
                defOf.set((Hashable*)n.res(), (Object*)n);
            }
        }

    final bool aggExpandOnce(IRModule* m, IRFunc* fn)
        {
        Map* defOf = aeDefMap(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            if (aeFoldSnapshot(fn, (IRBlock*)fn.blocks().get(b), defOf))
                return true;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            if (aeSplitCopy(m, fn, (IRBlock*)fn.blocks().get(b)))
                return true;
        return false;
        }

    final bool aeFoldSnapshot(IRFunc* fn, IRBlock* bb, Map* defOf)
        {
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* ld = (IRInsn*)bb.insns().get(i);
            if (!ld.op().equals(String.withCString("Load")))
                continue;
            if (ld.res() == (IRValue*)0 || !aeIsAgg(ld.res().ty()))
                continue;
            if (ld.memRes() == (IRValue*)0 || ld.ops().count() < (u32)2)
                continue;
            IROperand* srcOp = (IROperand*)ld.ops().get((u32)0);
            if (srcOp.kind() != (u8)OPK_USE)
                continue;

            Array* addrs = self.aeUsersOf(fn, ld.res());
            if (addrs.count() == (u32)0)
                continue;
            Array* fields = new Array();
            bool ok = true;
            for (u32 a = (u32)0; a < addrs.count() && ok; a = a + (u32)1)
                {
                IRInsn* ao = (IRInsn*)addrs.get(a);
                if (!ao.op().equals(String.withCString("AddrOf")) || ao.res() == (IRValue*)0)
                    {
                    ok = false;
                    }
                else
                    {
                    Array* fu = self.aeUsersOf(fn, ao.res());
                    if (fu.count() == (u32)0)
                        ok = false;
                    for (u32 q = (u32)0; q < fu.count() && ok; q = q + (u32)1)
                        {
                        IRInsn* f = (IRInsn*)fu.get(q);
                        if (!f.op().equals(String.withCString("FieldAddr")))
                            ok = false;
                        else
                            fields.add((Object*)f);
                        }
                    }
                }
            if (!ok || fields.count() == (u32)0)
                continue;

            // Everything that reads the snapshot must sit in this block, after
            // the load, and nothing in between may write the memory it reads.
            u32 last = i;
            for (u32 q = (u32)0; q < fields.count() && ok; q = q + (u32)1)
                {
                u32 at = aeIndexOf(bb.insns(), (IRInsn*)fields.get(q));
                if (at >= bb.insns().count() || at < i)
                    ok = false;
                else if (at > last)
                    last = at;
                }
            for (u32 q = (u32)0; q < addrs.count() && ok; q = q + (u32)1)
                {
                u32 at = aeIndexOf(bb.insns(), (IRInsn*)addrs.get(q));
                if (at >= bb.insns().count() || at < i)
                    ok = false;
                else if (at > last)
                    last = at;
                }
            if (!ok)
                continue;

            for (u32 j = i + (u32)1; j <= last && ok; j = j + (u32)1)
                {
                IRInsn* mid = (IRInsn*)bb.insns().get(j);
                if (mid.op().equals(String.withCString("Store")) && mid.ops().count() >= (u32)1
                    && ((IROperand*)mid.ops().get((u32)0)).kind() == (u8)OPK_USE)
                    ok = !aeMayAlias(fn, ((IROperand*)mid.ops().get((u32)0)).val(),
                                     srcOp.val(), defOf);
                else if (mid.memRes() != (IRValue*)0
                         && !mid.op().equals(String.withCString("Load")))
                    ok = false;         // a call, or anything else opaque
                }
            if (!ok)
                continue;

            for (u32 q = (u32)0; q < fields.count(); q = q + (u32)1)
                ((IRInsn*)fields.get(q)).ops().set((u32)0, (Object*)IROperand.useVal(srcOp.val()));
            aeReplaceUses(fn, ld.memRes(), (IROperand*)ld.ops().get((u32)1));

            Array* keep = new Array();
            for (u32 q = (u32)0; q < bb.insns().count(); q = q + (u32)1)
                {
                IRInsn* x = (IRInsn*)bb.insns().get(q);
                bool drop = (x == ld);
                for (u32 a = (u32)0; a < addrs.count() && !drop; a = a + (u32)1)
                    if ((IRInsn*)addrs.get(a) == x)
                        drop = true;
                if (!drop)
                    keep.add((Object*)x);
                }
            aeSetInsns(bb, keep);
            return true;
            }
        return false;
        }

    final void aeSetInsns(IRBlock* bb, Array* keep)
        {
        while (bb.insns().count() > (u32)0)
            bb.insns().removeAt(bb.insns().count() - (u32)1);
        for (u32 q = (u32)0; q < keep.count(); q = q + (u32)1)
            bb.insns().add(keep.get(q));
        }

    final bool aeSplitCopy(IRModule* m, IRFunc* fn, IRBlock* bb)
        {
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* ld = (IRInsn*)bb.insns().get(i);
            if (!ld.op().equals(String.withCString("Load")))
                continue;
            if (ld.res() == (IRValue*)0 || ld.memRes() == (IRValue*)0)
                continue;
            if (!aeIsAgg(ld.res().ty()) || ld.ops().count() < (u32)2)
                continue;
            IROperand* srcOp = (IROperand*)ld.ops().get((u32)0);
            if (srcOp.kind() != (u8)OPK_USE)
                continue;
            Array* u = self.aeUsersOf(fn, ld.res());
            if (u.count() != (u32)1)
                continue;
            IRInsn* st = (IRInsn*)u.get((u32)0);
            if (!st.op().equals(String.withCString("Store")) || st.memRes() == (IRValue*)0)
                continue;
            if (st.ops().count() < (u32)3)
                continue;
            IROperand* dstOp = (IROperand*)st.ops().get((u32)0);
            IROperand* valOp = (IROperand*)st.ops().get((u32)1);
            if (dstOp.kind() != (u8)OPK_USE || valOp.kind() != (u8)OPK_USE
                || valOp.val() != ld.res())
                continue;
            u32 si = aeIndexOf(bb.insns(), st);
            if (si >= bb.insns().count() || si <= i)
                continue;
            // A field address needs a pointer to the aggregate itself. A copy
            // into a byte buffer (the variadic pack) stores through a U8
            // pointer, where every FieldAddr would land on byte 0.
            if (!aePointsTo(srcOp.val(), ld.res().ty()) || !aePointsTo(dstOp.val(), ld.res().ty()))
                continue;

            u32 lid = self.aeLayoutId(m, ld.res().ty());
            if (lid >= m.layouts().count())
                continue;
            IRLayout* lay = (IRLayout*)m.layouts().get(lid);
            u32 n = lay.fieldCount();
            if (n == (u32)0 || n > aeMaxFields())
                continue;
            bool scalarOnly = true;
            for (u32 f = (u32)0; f < n; f = f + (u32)1)
                {
                String* ft = lay.typeAt(f);
                if (ft == (String*)0 || aeIsAgg(ft) || ft.equals(String.withCString("Mem")))
                    scalarOnly = false;
                }
            if (!scalarOnly)
                continue;

            // The field loads, at the aggregate load's position.
            Array* loads = new Array();
            Array* vals = new Array();
            IRValue* mem = ((IROperand*)ld.ops().get((u32)1)).val();
            for (u32 f = (u32)0; f < n; f = f + (u32)1)
                {
                String* ft = lay.typeAt(f);
                IRValue* sa = new IRValue(aePtrTo(ft));
                IRInsn* fa = IRInsn.with(String.withCString("FieldAddr"));
                fa.copyDbg(ld);
                fa.setRes(sa);
                fa.add(IROperand.useVal(srcOp.val()));
                fa.add(IROperand.immU(f, String.withCString("U8")));
                loads.add((Object*)fa);

                IRValue* fv = new IRValue(ft);
                IRValue* mv = ld.memRes();
                if (f + (u32)1 < n)
                    mv = new IRValue(String.withCString("Mem"));
                IRInsn* fl = IRInsn.with(String.withCString("Load"));
                fl.copyDbg(ld);
                fl.setRes(fv);
                fl.setMemRes(mv);
                fl.add(IROperand.useVal(sa));
                fl.add(IROperand.useVal(mem));
                loads.add((Object*)fl);
                vals.add((Object*)fv);
                mem = mv;
                }

            // The field stores, at the aggregate store's position.
            Array* stores = new Array();
            mem = ((IROperand*)st.ops().get((u32)2)).val();
            for (u32 f = (u32)0; f < n; f = f + (u32)1)
                {
                String* ft = lay.typeAt(f);
                IRValue* da = new IRValue(aePtrTo(ft));
                IRInsn* fa = IRInsn.with(String.withCString("FieldAddr"));
                fa.copyDbg(st);
                fa.setRes(da);
                fa.add(IROperand.useVal(dstOp.val()));
                fa.add(IROperand.immU(f, String.withCString("U8")));
                stores.add((Object*)fa);

                IRValue* mv = st.memRes();
                if (f + (u32)1 < n)
                    mv = new IRValue(String.withCString("Mem"));
                IRInsn* fs = IRInsn.with(String.withCString("Store"));
                fs.copyDbg(st);
                fs.setMemRes(mv);
                fs.add(IROperand.useVal(da));
                fs.add(IROperand.useVal((IRValue*)vals.get(f)));
                fs.add(IROperand.useVal(mem));
                stores.add((Object*)fs);
                mem = mv;
                }

            Array* out = new Array();
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                {
                if (k == i)
                    {
                    for (u32 q = (u32)0; q < loads.count(); q = q + (u32)1)
                        out.add(loads.get(q));
                    }
                else if (k == si)
                    {
                    for (u32 q = (u32)0; q < stores.count(); q = q + (u32)1)
                        out.add(stores.get(q));
                    }
                else
                    {
                    out.add(bb.insns().get(k));
                    }
                }
            aeSetInsns(bb, out);
            return true;
            }
        return false;
        }

    // YES if `p` is typed as a pointer to exactly `agg`, in any window.
    final bool aePointsTo(IRValue* p, String* agg)
        {
        if (p == (IRValue*)0 || p.ty() == (String*)0 || agg == (String*)0)
            return false;
        String* want = String.withCString("Ptr(");
        want.append(agg);
        want.appendCString(",");
        return p.ty().hasPrefix(want);
        }

    final String* aePtrTo(String* ty)
        {
        String* s = String.withCString("Ptr(");
        s.append(ty);
        s.appendCString(", unbanked)");
        return s;
        }
    }
