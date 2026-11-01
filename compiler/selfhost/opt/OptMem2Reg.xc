// OptMem2Reg.xc — the Mem2Reg pass, ported from src/xtc/ir/XTIROptMem2Reg.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptAggExpand>

    class Opt (Mem2Reg)
    {

    final void mem2reg(IRModule* m)
        {
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            m2rFunc(m, (IRFunc*)m.funcs().get(f));
            if (optPromoteScalars())
                m2rDeadPhis((IRFunc*)m.funcs().get(f));
            }
        }

    // A C module's phis that nothing reads, gone: phi placement does not ask
    // whether a local is live, so a local declared inside a loop gets one at
    // the loop's header, which then reads as a carried value.
    final void m2rDeadPhis(IRFunc* fn)
        {
        // Live: what an instruction other than a phi reads, and what a live
        // phi reads, to a fixed point. (Two phis that read only each other, a
        // local declared inside a nest, are dead together.)
        Set* live = new Set();
        Array* phis = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            phis.addAll(bb.phis());
            Array* all = new Array();
            all.addAll(bb.insns());
            if (bb.term() != (IRInsn*)0)
                all.add((Object*)bb.term());
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)all.get(i);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                        live.add((Hashable*)o.val());
                    }
                }
            }
        bool grew = true;
        while (grew)
            {
            grew = false;
            for (u32 i = (u32)0; i < phis.count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)phis.get(i);
                if (p.res() == (IRValue*)0 || !live.contains((Hashable*)p.res()))
                    continue;
                for (u32 k = (u32)0; k < p.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)p.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0 && !live.contains((Hashable*)o.val()))
                        {
                        live.add((Hashable*)o.val());
                        grew = true;
                        }
                    }
                }
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* keep = new Array();
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() == (IRValue*)0 || live.contains((Hashable*)p.res()))
                    keep.add((Object*)p);
                }
            if (keep.count() != bb.phis().count())
                bb.setPhis(keep);
            }
        }
    final IROperand* m2rUndef(IRFunc* fn, u32 vi, bool dry)
        {
        if (dry)
            return IROperand.immI((i64)0, String.withCString("I32"));
        Number* key = Number.with(vi);
        Object* have = _m2rUndefs.get((Hashable*)key);
        if (have != (Object*)0)
            return (IROperand*)have;
        String* t = (String*)_m2rType.get(vi);
        IRInsn* c = IRInsn.with(String.withCString("Const"));
        IRValue* z = (IRValue*)0;
        if (t.hasPrefix(String.withCString("F")))
            {
            z = new IRValue(t);
            c.add(IROperand.immF(String.withCString("0000000000000000"), t));
            }
        else if (t.hasPrefix(String.withCString("Ptr(")))
            {
            // A null pointer: zero, then the pointer.
            IRValue* zi = new IRValue(String.withCString("I64"));
            c.add(IROperand.immI((i64)0, String.withCString("I64")));
            c.setRes(zi);
            IRBlock* e0 = (IRBlock*)fn.blocks().get((u32)0);
            e0.insns().insert((u32)0, (Object*)c);
            IRInsn* ip = IRInsn.with(String.withCString("IntToPtr"));
            z = new IRValue(t);
            ip.setRes(z);
            ip.add(IROperand.useVal(zi));
            e0.insns().insert((u32)1, (Object*)ip);
            IROperand* po = IROperand.useVal(z);
            _m2rUndefs.set((Hashable*)key, (Object*)po);
            return po;
            }
        else
            {
            z = new IRValue(t);
            c.add(IROperand.immI((i64)0, t));
            }
        c.setRes(z);
        ((IRBlock*)fn.blocks().get((u32)0)).insns().insert((u32)0, (Object*)c);
        IROperand* o = IROperand.useVal(z);
        _m2rUndefs.set((Hashable*)key, (Object*)o);
        return o;
        }

    final void m2rFunc(IRModule* m, IRFunc* fn)
        {
        _m2rUndefs = new Map();
        if (fn.blocks().count() == (u32)0 || fn.pinned().count() == (u32)0)
            return;

        _m2rLocal = new Array();
        _m2rField = new Array();
        _m2rType = new Array();
        _m2rPtrVar = new Map();
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1)
            m2rCollect(m, fn, (IRPinned*)fn.pinned().get(i));
        if (_m2rLocal.count() == (u32)0)
            return;

        // A phi needs one incoming per predecessor, and an unreachable one is
        // not a block the dominator relation knows about — the phis this pass
        // writes would be short an entry. Rare enough to simply decline.
        if (!m2rAllReachable(fn))
            return;
        m2rBuildTree(fn);

        _m2rBad = new Array();
        for (u32 i = (u32)0; i < _m2rLocal.count(); i = i + (u32)1)
            _m2rBad.add((Object*)Number.with((u32)0));

        // Dry run first: a field READ on a path that never wrote it cannot be
        // promoted — there is no value to name. Drop those and retry, because
        // dropping one can only ever help the others.
        for (u32 attempt = (u32)0; attempt < (u32)4; attempt = attempt + (u32)1)
            {
            u32 before = m2rBadCount();
            m2rPlacePhis(fn, true);
            m2rRename(fn, (IRBlock*)fn.blocks().get((u32)0), m2rFreshStacks(), true);
            if (m2rBadCount() == before)
                attempt = (u32)4;
            }
        if (m2rBadCount() >= _m2rLocal.count())
            return;

        _m2rValueMap = new Map();
        _m2rDead = new Array();
        m2rPlacePhis(fn, false);
        m2rRename(fn, (IRBlock*)fn.blocks().get((u32)0), m2rFreshStacks(), false);
        m2rCommit(fn);
        }

    final u32 m2rBadCount(void)
        {
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < _m2rBad.count(); i = i + (u32)1)
            if (((Number*)_m2rBad.get(i)).asU32() != (u32)0)
                n = n + (u32)1;
        return n;
        }

    final bool m2rIsBad(u32 vi)
        {
        return ((Number*)_m2rBad.get(vi)).asU32() != (u32)0;
        }

    final void m2rMarkBad(u32 vi)
        {
        _m2rBad.set(vi, (Object*)Number.with((u32)1));
        }

    final Array* m2rFreshStacks(void)
        {
        Array* s = new Array();
        for (u32 i = (u32)0; i < _m2rLocal.count(); i = i + (u32)1)
            s.add((Object*)new Array());
        return s;
        }

    final bool m2rAllReachable(IRFunc* fn)
        {
        Array* seen = new Array();
        Array* work = new Array();
        work.add(fn.blocks().get((u32)0));
        seen.add(fn.blocks().get((u32)0));
        while (work.count() > (u32)0)
            {
            IRBlock* bb = (IRBlock*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            Array* succ = m2rSuccs(bb);
            for (u32 i = (u32)0; i < succ.count(); i = i + (u32)1)
                {
                IRBlock* s = (IRBlock*)succ.get(i);
                if (!self.hasBlock(seen, s))
                    {
                    seen.add((Object*)s);
                    work.add((Object*)s);
                    }
                }
            }
        return seen.count() == fn.blocks().count();
        }

    final Array* m2rSuccs(IRBlock* bb)
        {
        Array* out = new Array();
        if (bb.term() == (IRInsn*)0)
            return out;
        for (u32 q = (u32)0; q < bb.term().ops().count(); q = q + (u32)1)
            {
            IROperand* o = (IROperand*)bb.term().ops().get(q);
            if (o.kind() == (u8)OPK_BLOCK && o.blk() != (IRBlock*)0
                && !self.hasBlock(out, o.blk()))
                out.add((Object*)o.blk());
            }
        return out;
        }

    // Predecessors, immediate dominators and dominator-tree children, all in
    // declaration order.
    final void m2rBuildTree(IRFunc* fn)
        {
        _m2rPreds = new Map();
        _m2rKids = new Map();
        _m2rIdom = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            _m2rPreds.set((Hashable*)bb, (Object*)new Array());
            _m2rKids.set((Hashable*)bb, (Object*)new Array());
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* succ = m2rSuccs(bb);
            for (u32 i = (u32)0; i < succ.count(); i = i + (u32)1)
                {
                Array* p = (Array*)_m2rPreds.get((Hashable*)(IRBlock*)succ.get(i));
                if (p != (Array*)0 && !self.hasBlock(p, bb))
                    p.add((Object*)bb);
                }
            }

        // idom(b) is the strict dominator of b with the MOST dominators of its
        // own — dominators of a block form a chain, so that is the nearest.
        Map* dom = self.dominators(fn);
        IRBlock* entry = (IRBlock*)fn.blocks().get((u32)0);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == entry)
                continue;
            Array* ds = (Array*)dom.get((Hashable*)bb);
            IRBlock* best = (IRBlock*)0;
            u32 bestN = (u32)0;
            for (u32 k = (u32)0; ds != (Array*)0 && k < ds.count(); k = k + (u32)1)
                {
                IRBlock* d = (IRBlock*)ds.get(k);
                if (d == bb)
                    continue;
                Array* dd = (Array*)dom.get((Hashable*)d);
                u32 n = dd == (Array*)0 ? (u32)0 : dd.count();
                if (best == (IRBlock*)0 || n > bestN)
                    {
                    best = d;
                    bestN = n;
                    }
                }
            if (best != (IRBlock*)0)
                _m2rIdom.set((Hashable*)bb, (Object*)best);
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* c = (IRBlock*)fn.blocks().get(b);
            Object* d = _m2rIdom.get((Hashable*)c);
            if (d != (Object*)0 && (IRBlock*)d != c)
                ((Array*)_m2rKids.get((Hashable*)(IRBlock*)d)).add((Object*)c);
            }
        }

    final bool m2rDominates(IRBlock* a, IRBlock* b)
        {
        IRBlock* cur = b;
        for (u32 hop = (u32)0; hop < (u32)4096; hop = hop + (u32)1)
            {
            if (cur == a)
                return true;
            Object* d = _m2rIdom.get((Hashable*)cur);
            if (d == (Object*)0 || (IRBlock*)d == cur)
                return false;
            cur = (IRBlock*)d;
            }
        return false;
        }

    // The dominance frontier: a block `b` reaches through some predecessor it
    // dominates, but does not itself strictly dominate.
    final bool m2rInFrontier(IRBlock* b, IRBlock* j)
        {
        Array* preds = (Array*)_m2rPreds.get((Hashable*)j);
        bool reaches = false;
        for (u32 i = (u32)0; preds != (Array*)0 && i < preds.count(); i = i + (u32)1)
            if (m2rDominates(b, (IRBlock*)preds.get(i)))
                reaches = true;
        if (!reaches)
            return false;
        if (b == j)
            return true;
        return !m2rDominates(b, j);
        }


    // A local qualifies when it is reached ONLY through
    // AddrOf -> FieldAddr(constant) -> scalar Load/Store.
    final void m2rCollect(IRModule* m, IRFunc* fn, IRPinned* pl)
        {
        if (!self.aeIsAgg(pl.ty()))
            {
            // A C local (optPromoteScalars()): the slot is one variable, and
            // each AddrOf of it is a pointer to that variable.
            if (!optPromoteScalars() || pl.ty().equals(String.withCString("Mem")))
                return;
            Array* sa = self.aeUsersOf(fn, pl.val());
            if (sa.count() == (u32)0)
                return;
            for (u32 a = (u32)0; a < sa.count(); a = a + (u32)1)
                {
                IRInsn* ao = (IRInsn*)sa.get(a);
                if (!ao.op().equals(String.withCString("AddrOf")) || ao.res() == (IRValue*)0)
                    return;
                if (!m2rFieldUsesOk(fn, ao, pl.ty()))
                    return;
                }
            u32 sv = _m2rLocal.count();
            _m2rLocal.add((Object*)pl.val());
            _m2rField.add((Object*)Number.with((u32)0));
            _m2rType.add((Object*)pl.ty());
            for (u32 a = (u32)0; a < sa.count(); a = a + (u32)1)
                _m2rPtrVar.set((Hashable*)((IRInsn*)sa.get(a)).res(), (Object*)Number.with(sv));
            return;
            }
        u32 lid = self.aeLayoutId(m, pl.ty());
        if (lid >= m.layouts().count())
            return;
        IRLayout* lay = (IRLayout*)m.layouts().get(lid);
        if (lay.fieldCount() == (u32)0)
            return;

        Array* addrs = self.aeUsersOf(fn, pl.val());
        if (addrs.count() == (u32)0)
            return;
        Array* ptrs = new Array();
        for (u32 a = (u32)0; a < addrs.count(); a = a + (u32)1)
            {
            IRInsn* ao = (IRInsn*)addrs.get(a);
            if (!ao.op().equals(String.withCString("AddrOf")) || ao.res() == (IRValue*)0)
                return;
            Array* fs = self.aeUsersOf(fn, ao.res());
            if (fs.count() == (u32)0)
                return;
            for (u32 q = (u32)0; q < fs.count(); q = q + (u32)1)
                {
                IRInsn* f = (IRInsn*)fs.get(q);
                if (!f.op().equals(String.withCString("FieldAddr")) || f.res() == (IRValue*)0)
                    return;
                if (f.ops().count() < (u32)2)
                    return;
                IROperand* ix = (IROperand*)f.ops().get((u32)1);
                if (ix.kind() != (u8)OPK_IMMI)
                    return;
                i64 k = ix.imm();
                if (k < (i64)0 || (u32)k >= lay.fieldCount())
                    return;
                String* ft = lay.typeAt((u32)k);
                // Plain scalars only — see the note in the original.
                if (ft == (String*)0 || self.aeIsAgg(ft) || m2rIsPtrTy(ft)
                    || ft.equals(String.withCString("Mem")))
                    return;
                if (!m2rFieldUsesOk(fn, f, ft))
                    return;
                ptrs.add((Object*)f);
                }
            }

        // Accepted: give every field index used its own variable. Found by
        // scanning what is already there rather than a keyed map, so the order
        // is the order the pointers were seen in and nothing depends on how a
        // map hashes a boxed integer.
        u32 first = _m2rLocal.count();
        for (u32 q = (u32)0; q < ptrs.count(); q = q + (u32)1)
            {
            IRInsn* f = (IRInsn*)ptrs.get(q);
            u32 k = (u32)((IROperand*)f.ops().get((u32)1)).imm();
            u32 vi = _m2rLocal.count();
            for (u32 e = first; e < _m2rLocal.count(); e = e + (u32)1)
                if (((Number*)_m2rField.get(e)).asU32() == k)
                    vi = e;
            if (vi == _m2rLocal.count())
                {
                _m2rLocal.add((Object*)pl.val());
                _m2rField.add((Object*)Number.with(k));
                _m2rType.add((Object*)lay.typeAt(k));
                }
            _m2rPtrVar.set((Hashable*)f.res(), (Object*)Number.with(vi));
            }
        }

    final bool m2rIsPtrTy(String* t)
        {
        if (t.byteLength() < (u32)4)
            return false;
        if (t.byteAt((u32)0) == (u8)'P' && t.byteAt((u32)1) == (u8)'t'
            && t.byteAt((u32)2) == (u8)'r' && t.byteAt((u32)3) == (u8)'(')
            return true;
        return t.byteAt((u32)0) == (u8)'V' && t.byteAt((u32)1) == (u8)'e'
               && t.byteAt((u32)2) == (u8)'c' && t.byteAt((u32)3) == (u8)'(';
        }

    // The field pointer must never be anything but the address a Load reads or
    // a Store writes — stored AS a value, or handed to a call, it escapes and
    // the frame slot is the only truth.
    final bool m2rFieldUsesOk(IRFunc* fn, IRInsn* f, String* ft)
        {
        Array* us = self.aeUsersOf(fn, f.res());
        for (u32 i = (u32)0; i < us.count(); i = i + (u32)1)
            {
            IRInsn* u = (IRInsn*)us.get(i);
            bool isLoad = u.op().equals(String.withCString("Load"));
            bool isStore = u.op().equals(String.withCString("Store"));
            if (!isLoad && !isStore)
                return false;
            if (u.ops().count() < (u32)2)
                return false;
            IROperand* a0 = (IROperand*)u.ops().get((u32)0);
            if (a0.kind() != (u8)OPK_USE || a0.val() != f.res())
                return false;
            for (u32 q = (u32)1; q < u.ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)u.ops().get(q);
                if (o.kind() == (u8)OPK_USE && o.val() == f.res())
                    return false;
                }
            if (isLoad && u.res() != (IRValue*)0 && !u.res().ty().equals(ft))
                return false;
            }
        return true;
        }

    // The variable a Load/Store's pointer operand names, or -1.
    final i32 m2rVarOf(IRInsn* n)
        {
        if (n.ops().count() == (u32)0)
            return (i32)-1;
        IROperand* o = (IROperand*)n.ops().get((u32)0);
        if (o.kind() != (u8)OPK_USE)
            return (i32)-1;
        Object* v = _m2rPtrVar.get((Hashable*)o.val());
        if (v == (Object*)0)
            return (i32)-1;
        u32 vi = ((Number*)v).asU32();
        if (m2rIsBad(vi))
            return (i32)-1;
        return (i32)vi;
        }

    final void m2rPlacePhis(IRFunc* fn, bool dry)
        {
        _m2rPhis = new Map();
        _m2rPhiVar = new Map();
        for (u32 vi = (u32)0; vi < _m2rLocal.count(); vi = vi + (u32)1)
            {
            if (m2rIsBad(vi))
                continue;
            Array* defs = new Array();
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                bool stores = false;
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                    {
                    IRInsn* n = (IRInsn*)bb.insns().get(i);
                    if (n.op().equals(String.withCString("Store"))
                        && m2rVarOf(n) == (i32)vi)
                        stores = true;
                    }
                if (stores)
                    defs.add((Object*)bb);
                }
            if (defs.count() == (u32)0)
                continue;
            Array* idf = m2rIteratedFrontier(fn, defs);
            for (u32 q = (u32)0; q < idf.count(); q = q + (u32)1)
                m2rAddPhi(fn, (IRBlock*)idf.get(q), vi, dry);
            }
        }

    final void m2rAddPhi(IRFunc* fn, IRBlock* j, u32 vi, bool dry)
        {
        Array* ps = (Array*)_m2rPhis.get((Hashable*)j);
        Array* vs = (Array*)_m2rPhiVar.get((Hashable*)j);
        if (ps == (Array*)0)
            {
            ps = new Array();
            vs = new Array();
            _m2rPhis.set((Hashable*)j, (Object*)ps);
            _m2rPhiVar.set((Hashable*)j, (Object*)vs);
            }
        // The dry run builds the phi WITHOUT a result: it needs a placeholder
        // in the array, and allocating a value id for a run whose only output
        // is a rejection list would shift every id the real run then hands out.
        IRInsn* phi = IRInsn.with(String.withCString("Phi"));
        if (!dry)
            {
            phi.setRes(new IRValue((String*)_m2rType.get(vi)));
            Array* preds = (Array*)_m2rPreds.get((Hashable*)j);
            for (u32 p = (u32)0; preds != (Array*)0 && p < preds.count(); p = p + (u32)1)
                {
                phi.add(IROperand.block((IRBlock*)preds.get(p)));
                phi.add(IROperand.useVal((IRValue*)0));
                }
            }
        ps.add((Object*)phi);
        vs.add((Object*)Number.with(vi));
        }

    // The iterated dominance frontier, to a fixed point. Both loops run in
    // declaration order so the RESULT'S ORDER is reproducible, not just its
    // members — the phis come out in this order and their value ids follow.
    final Array* m2rIteratedFrontier(IRFunc* fn, Array* defs)
        {
        Array* out = new Array();
        Array* seeds = new Array();
        for (u32 i = (u32)0; i < defs.count(); i = i + (u32)1)
            seeds.add(defs.get(i));
        bool changed = true;
        while (changed)
            {
            changed = false;
            for (u32 bi = (u32)0; bi < fn.blocks().count(); bi = bi + (u32)1)
                {
                IRBlock* b = (IRBlock*)fn.blocks().get(bi);
                if (!self.hasBlock(seeds, b))
                    continue;
                for (u32 ji = (u32)0; ji < fn.blocks().count(); ji = ji + (u32)1)
                    {
                    IRBlock* j = (IRBlock*)fn.blocks().get(ji);
                    if (hasBlock(out, j) || !m2rInFrontier(b, j))
                        continue;
                    out.add((Object*)j);
                    seeds.add((Object*)j);
                    changed = true;
                    }
                }
            }
        return out;
        }

    final void m2rRename(IRFunc* fn, IRBlock* bb, Array* stacks, bool dry)
        {
        Array* pushed = new Array();
        for (u32 i = (u32)0; i < _m2rLocal.count(); i = i + (u32)1)
            pushed.add((Object*)Number.with((u32)0));

        Array* pv = (Array*)_m2rPhiVar.get((Hashable*)bb);
        Array* pi = (Array*)_m2rPhis.get((Hashable*)bb);
        for (u32 k = (u32)0; pv != (Array*)0 && k < pv.count(); k = k + (u32)1)
            {
            u32 vi = ((Number*)pv.get(k)).asU32();
            if (m2rIsBad(vi))
                continue;
            IROperand* val = IROperand.useVal((IRValue*)0);
            if (!dry)
                val = IROperand.useVal(((IRInsn*)pi.get(k)).res());
            ((Array*)stacks.get(vi)).add((Object*)val);
            m2rBump(pushed, vi);
            }

        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)bb.insns().get(i);
            i32 vn = m2rVarOf(n);
            if (vn < (i32)0)
                continue;
            u32 vi = (u32)vn;
            Array* st = (Array*)stacks.get(vi);
            if (n.op().equals(String.withCString("Load")))
                {
                // A C local read before it is written is undefined there: any
                // value does, so zero (only for C: optPromoteScalars()).
                if (st.count() == (u32)0 && optPromoteScalars())
                    st.add((Object*)m2rUndef(fn, vi, dry));
                if (st.count() == (u32)0)
                    m2rMarkBad(vi);
                else if (!dry && n.res() != (IRValue*)0)
                    {
                    _m2rValueMap.set((Hashable*)n.res(),
                                     st.get(st.count() - (u32)1));
                    _m2rDead.add((Object*)n);
                    }
                }
            else if (n.op().equals(String.withCString("Store")) && n.ops().count() >= (u32)2)
                {
                st.add((Object*)m2rResolve((IROperand*)n.ops().get((u32)1), dry));
                m2rBump(pushed, vi);
                if (!dry)
                    _m2rDead.add((Object*)n);
                }
            }

        Array* succ = m2rSuccs(bb);
        for (u32 si = (u32)0; si < succ.count(); si = si + (u32)1)
            {
            IRBlock* s = (IRBlock*)succ.get(si);
            Array* spv = (Array*)_m2rPhiVar.get((Hashable*)s);
            Array* spi = (Array*)_m2rPhis.get((Hashable*)s);
            for (u32 k = (u32)0; spv != (Array*)0 && k < spv.count(); k = k + (u32)1)
                {
                u32 vi = ((Number*)spv.get(k)).asU32();
                if (m2rIsBad(vi))
                    continue;
                Array* st = (Array*)stacks.get(vi);
                // A phi's edge on which a C local has not been written yet
                // (one placed for a loop the local is dead in): zero.
                IROperand* undef = (IROperand*)0;
                if (st.count() == (u32)0 && optPromoteScalars())
                    undef = m2rUndef(fn, vi, dry);
                if (st.count() == (u32)0 && undef == (IROperand*)0)
                    {
                    m2rMarkBad(vi);
                    continue;
                    }
                if (dry)
                    continue;
                IRInsn* phi = (IRInsn*)spi.get(k);
                if (undef != (IROperand*)0)
                    {
                    for (u32 q = (u32)0; q + (u32)1 < phi.ops().count(); q = q + (u32)2)
                        if (((IROperand*)phi.ops().get(q)).blk() == bb)
                            phi.ops().set(q + (u32)1, undef);
                    continue;
                    }
                for (u32 q = (u32)0; q + (u32)1 < phi.ops().count(); q = q + (u32)2)
                    if (((IROperand*)phi.ops().get(q)).blk() == bb)
                        phi.ops().set(q + (u32)1, st.get(st.count() - (u32)1));
                }
            }

        Array* kids = (Array*)_m2rKids.get((Hashable*)bb);
        for (u32 k = (u32)0; kids != (Array*)0 && k < kids.count(); k = k + (u32)1)
            m2rRename(fn, (IRBlock*)kids.get(k), stacks, dry);

        for (u32 vi = (u32)0; vi < _m2rLocal.count(); vi = vi + (u32)1)
            {
            u32 n = ((Number*)pushed.get(vi)).asU32();
            Array* st = (Array*)stacks.get(vi);
            while (n > (u32)0 && st.count() > (u32)0)
                {
                st.removeAt(st.count() - (u32)1);
                n = n - (u32)1;
                }
            }
        }

    final void m2rBump(Array* pushed, u32 vi)
        {
        pushed.set(vi, (Object*)Number.with(((Number*)pushed.get(vi)).asU32() + (u32)1));
        }

    // A stored value may itself be a load this pass has already replaced, so
    // it is resolved AT PUSH TIME — which is what keeps the value map one
    // level deep.
    final IROperand* m2rResolve(IROperand* op, bool dry)
        {
        if (dry || op == (IROperand*)0 || op.kind() != (u8)OPK_USE)
            return op;
        Object* r = _m2rValueMap.get((Hashable*)op.val());
        if (r == (Object*)0)
            return op;
        return (IROperand*)r;
        }

    final void m2rCommit(IRFunc* fn)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* ps = (Array*)_m2rPhis.get((Hashable*)bb);
            Array* vs = (Array*)_m2rPhiVar.get((Hashable*)bb);
            for (u32 k = (u32)0; ps != (Array*)0 && k < ps.count(); k = k + (u32)1)
                if (!m2rIsBad(((Number*)vs.get(k)).asU32()))
                    bb.phis().add(ps.get(k));
            }

        // Point every reader of a promoted load at the value it now names.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            m2rRemapIn(bb.phis());
            m2rRemapIn(bb.insns());
            if (bb.term() != (IRInsn*)0)
                m2rRemapOne(bb.term());
            }

        // Drop the loads and stores, IN PROGRAM ORDER so each one's memory
        // result forwards onto an input its predecessor has already rewritten.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (!m2rIsDead(n) || n.memRes() == (IRValue*)0)
                    continue;
                u32 mi = n.op().equals(String.withCString("Store")) ? (u32)2 : (u32)1;
                if (mi >= n.ops().count())
                    continue;
                self.aeReplaceUses(fn, n.memRes(), (IROperand*)n.ops().get(mi));
                }
            }
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            Array* keep = new Array();
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (!m2rIsDead((IRInsn*)bb.insns().get(i)))
                    keep.add(bb.insns().get(i));
            self.aeSetInsns(bb, keep);
            }
        }

    final bool m2rIsDead(IRInsn* n)
        {
        for (u32 i = (u32)0; i < _m2rDead.count(); i = i + (u32)1)
            if ((IRInsn*)_m2rDead.get(i) == n)
                return true;
        return false;
        }

    final void m2rRemapIn(Array* insns)
        {
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1)
            m2rRemapOne((IRInsn*)insns.get(i));
        }

    final void m2rRemapOne(IRInsn* n)
        {
        for (u32 q = (u32)0; q < n.ops().count(); q = q + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(q);
            if (o.kind() != (u8)OPK_USE)
                continue;
            Object* r = _m2rValueMap.get((Hashable*)o.val());
            if (r != (Object*)0)
                n.ops().set(q, r);
            }
        }
    }
