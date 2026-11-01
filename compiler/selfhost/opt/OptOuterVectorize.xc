// OptOuterVectorize.xc — the OuterVectorize pass, ported from src/xtc/ir/XTIROptOuterVectorize.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptBlockMerge>
#import <OptVectorizeParts>
#import <OptVectorizeRewrite>

    class Opt (OuterVectorize)
    {

    final u32 ovRoleOf(IROperand* o)
        {
        if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
            return (u32)0;
        Object* r = _ovRole.get((Hashable*)o.val());
        return r == (Object*)0 ? (u32)0 : ((Number*)r).asU32();
        }

    final u32 ovRoleOfVal(IRValue* v)
        {
        Object* r = _ovRole.get((Hashable*)v);
        return r == (Object*)0 ? (u32)0 : ((Number*)r).asU32();
        }

    final bool ovConst(IROperand* o, Map* defOf, i64* out)
        {
        if (o.kind() == (u8)OPK_IMMI)
            {
            out[0] = o.imm();
            return true;
            }
        if (o.kind() != (u8)OPK_USE)
            return false;
        Object* dd = defOf.get((Hashable*)o.val());
        if (dd == (Object*)0)
            return false;
        IRInsn* d = (IRInsn*)dd;
        if (d.op().equals(String.withCString("ZExt")) && d.ops().count() >= (u32)1
            && ((IROperand*)d.ops().get((u32)0)).kind() == (u8)OPK_USE)
            {
            Object* d2 = defOf.get((Hashable*)((IROperand*)d.ops().get((u32)0)).val());
            if (d2 == (Object*)0)
                return false;
            d = (IRInsn*)d2;
            }
        if (!d.op().equals(String.withCString("Const")) || d.ops().count() < (u32)1)
            return false;
        IROperand* k = (IROperand*)d.ops().get((u32)0);
        if (k.kind() != (u8)OPK_IMMI)
            return false;
        out[0] = k.imm();
        return true;
        }

    static bool ovHeaderOk(IRBlock* H)
        {
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            String* op = ((IRInsn*)H.insns().get(i)).op();
            if (!op.equals(String.withCString("Const")) && !op.equals(String.withCString("ZExt"))
                && !op.equals(String.withCString("ICmp")))
                return false;
            }
        return true;
        }

    // FAdd/FSub/FMul too, on f32 lanes (the reference explains).
    static bool ovArith(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("Sub"))
            || op.equals(String.withCString("Mul")) || op.equals(String.withCString("And"))
            || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor"))
            || op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub"))
            || op.equals(String.withCString("FMul"));
        }

    final IRValue* ovRoot(IRValue* v, Map* defOf)
        {
        _ovRootName = (String*)0;
        for (u32 hop = (u32)0; hop < (u32)16; hop = hop + (u32)1)
            {
            Object* dd = defOf.get((Hashable*)v);
            if (dd == (Object*)0)
                return (IRValue*)0;
            IRInsn* d = (IRInsn*)dd;
            if (d.ops().count() < (u32)1)
                return (IRValue*)0;
            IROperand* o = (IROperand*)d.ops().get((u32)0);
            if (d.op().equals(String.withCString("AddrOf")))
                {
                if (o.kind() == (u8)OPK_USE)
                    return o.val();
                if (o.kind() == (u8)OPK_SYM && o.name() != (String*)0)
                    _ovRootName = o.name();
                return (IRValue*)0;
                }
            // An `_xtc_new_<T>` allocator's result: an array of its own (the
            // reference explains).
            if (d.op().equals(String.withCString("Call")))
                {
                if (o.kind() == (u8)OPK_SYM && o.name() != (String*)0
                    && o.name().hasPrefix(String.withCString("_xtc_new_")) && d.res() != (IRValue*)0)
                    return d.res();
                return (IRValue*)0;
                }
            if ((d.op().equals(String.withCString("ElementAddr")) || d.op().equals(String.withCString("FieldAddr")))
                && o.kind() == (u8)OPK_USE)
                {
                v = o.val();
                continue;
                }
            return (IRValue*)0;
            }
        return (IRValue*)0;
        }

    // Record the root of `p` in vals / names; false when it has none.
    final bool ovAddRoot(IRValue* p, Map* defOf, Array* vals, Array* names)
        {
        IRValue* r = ovRoot(p, defOf);
        if (r != (IRValue*)0)
            {
            vals.add((Object*)r);
            return true;
            }
        if (_ovRootName == (String*)0)
            return false;
        names.add((Object*)_ovRootName);
        return true;
        }

    final void outerVectorize(IRModule* m)
        {
        if (!_profile.vectorize())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            // A dispatch clone carries its own vector width (bug 644).
            _vecFnBytes = fn.simdLaneBytes();
            u32 guard = (u32)0;
            while (guard < (u32)16 && ovOnce(fn))
                guard = guard + (u32)1;
            }
        _vecFnBytes = (u32)0;
        }

    final Array* ovPreds(IRFunc* fn, IRBlock* b)
        {
        Array* ps = new Array();
        for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
            {
            IRBlock* x = (IRBlock*)fn.blocks().get(i);
            IRInsn* t = x.term();
            if (t == (IRInsn*)0)
                continue;
            for (u32 q = (u32)0; q < t.ops().count(); q = q + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(q);
                if (o.kind() == (u8)OPK_BLOCK && o.blk() == b)
                    {
                    ps.add((Object*)x);
                    break;
                    }
                }
            }
        return ps;
        }

    final bool ovOnce(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* p = (IRInsn*)bb.phis().get(i);
                if (p.res() == (IRValue*)0)
                    continue;
                defOf.set((Hashable*)p.res(), (Object*)p);
                defBlk.set((Hashable*)p.res(), (Object*)bb);
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() == (IRValue*)0)
                    continue;
                defOf.set((Hashable*)n.res(), (Object*)n);
                defBlk.set((Hashable*)n.res(), (Object*)bb);
                }
            }
        for (u32 hb = (u32)0; hb < fn.blocks().count(); hb = hb + (u32)1)
            if (ovTry(fn, (IRBlock*)fn.blocks().get(hb), defOf, defBlk))
                return true;
        return false;
        }

    final bool ovTry(IRFunc* fn, IRBlock* Hj, Map* defOf, Map* defBlk)
        {
        IRInsn* tj = Hj.term();
        if (tj == (IRInsn*)0 || !tj.op().equals(String.withCString("CondBranch")) || tj.ops().count() < (u32)3
            || Hj.phis().count() != (u32)1)
            return false;
        if (!ovHeaderOk(Hj) || ((IROperand*)tj.ops().get((u32)0)).kind() != (u8)OPK_USE)
            return false;
        Object* gjo = defOf.get((Hashable*)((IROperand*)tj.ops().get((u32)0)).val());
        IRInsn* jPhi = (IRInsn*)Hj.phis().get((u32)0);
        if (gjo == (Object*)0 || jPhi.res() == (IRValue*)0)
            return false;
        IRInsn* gj = (IRInsn*)gjo;
        if (!gj.op().equals(String.withCString("ICmp")) || gj.pred() == (String*)0
            || !gj.pred().equals(String.withCString("ULT")) || gj.ops().count() < (u32)2
            || ((IROperand*)gj.ops().get((u32)0)).kind() != (u8)OPK_USE
            || ((IROperand*)gj.ops().get((u32)0)).val() != jPhi.res() || jPhi.ops().count() != (u32)4)
            return false;
        i64 trip = (i64)0;
        if (!ovConst((IROperand*)gj.ops().get((u32)1), defOf, &trip))
            return false;
        IRBlock* Bj = ((IROperand*)tj.ops().get((u32)1)).blk();
        if (Bj == (IRBlock*)0 || Bj == Hj || ovPreds(fn, Bj).count() != (u32)1)
            return false;
        if (Bj.phis().count() != (u32)0 || Bj.term() == (IRInsn*)0 || !Bj.term().op().equals(String.withCString("Branch")))
            return false;
        for (u32 i = (u32)0; i < Bj.insns().count(); i = i + (u32)1)
            {
            String* op = ((IRInsn*)Bj.insns().get(i)).op();
            if (!op.equals(String.withCString("Const")) && !op.equals(String.withCString("ZExt")))
                return false;
            }
        IRBlock* Hk = ((IROperand*)Bj.term().ops().get((u32)0)).blk();
        if (Hk == (IRBlock*)0 || Hk == Hj || Hk.phis().count() != (u32)2 || !ovHeaderOk(Hk))
            return false;
        IRInsn* tk = Hk.term();
        if (tk == (IRInsn*)0 || !tk.op().equals(String.withCString("CondBranch")) || tk.ops().count() < (u32)3
            || ((IROperand*)tk.ops().get((u32)0)).kind() != (u8)OPK_USE)
            return false;
        Object* gko = defOf.get((Hashable*)((IROperand*)tk.ops().get((u32)0)).val());
        if (gko == (Object*)0)
            return false;
        IRInsn* gk = (IRInsn*)gko;
        if (!gk.op().equals(String.withCString("ICmp")) || gk.ops().count() < (u32)2
            || ((IROperand*)gk.ops().get((u32)0)).kind() != (u8)OPK_USE)
            return false;
        IRBlock* Bk = ((IROperand*)tk.ops().get((u32)1)).blk();
        IRBlock* Ek = ((IROperand*)tk.ops().get((u32)2)).blk();
        if (Bk == (IRBlock*)0 || Ek == (IRBlock*)0 || Bk == Hk || Ek == Hk || Bk == Ek)
            return false;
        if (Bk.term() == (IRInsn*)0 || !Bk.term().op().equals(String.withCString("Branch"))
            || ((IROperand*)Bk.term().ops().get((u32)0)).blk() != Hk)
            return false;
        if (Ek.term() == (IRInsn*)0 || !Ek.term().op().equals(String.withCString("Branch"))
            || ((IROperand*)Ek.term().ops().get((u32)0)).blk() != Hj)
            return false;
        Array* pk = ovPreds(fn, Hk);
        if (ovPreds(fn, Bk).count() != (u32)1 || ovPreds(fn, Ek).count() != (u32)1 || pk.count() != (u32)2
            || !Opt.bmHas(pk, Bj) || !Opt.bmHas(pk, Bk))
            return false;
        if (Bk.phis().count() != (u32)0 || Ek.phis().count() != (u32)0)
            return false;
        // A large inner body (MD5's rounds) is left to the reduction
        // vectoriser: the outer form holds the outer body's splats across
        // it, and it needs the vector registers for its own values.
        if (Bk.insns().count() > (u32)VEC_SPLAT_BIG_BODY)
            return false;
        Array* pj = ovPreds(fn, Hj);
        if (pj.count() != (u32)2 || !Opt.bmHas(pj, Ek))
            return false;

        IROperand* jInit = (IROperand*)0;
        IROperand* jBack = (IROperand*)0;
        for (u32 q = (u32)0; q + (u32)1 < (u32)4; q = q + (u32)2)
            {
            if (((IROperand*)jPhi.ops().get(q)).blk() == Ek)
                jBack = (IROperand*)jPhi.ops().get(q + (u32)1);
            else
                jInit = (IROperand*)jPhi.ops().get(q + (u32)1);
            }
        i64 j0 = (i64)-1;
        if (jInit == (IROperand*)0 || jBack == (IROperand*)0 || !ovConst(jInit, defOf, &j0) || j0 != (i64)0
            || jBack.kind() != (u8)OPK_USE)
            return false;
        Object* jno = defOf.get((Hashable*)jBack.val());
        if (jno == (Object*)0)
            return false;
        IRInsn* jNext = (IRInsn*)jno;
        i64 jStep = (i64)0;
        if (!jNext.op().equals(String.withCString("Add")) || (IRBlock*)defBlk.get((Hashable*)jBack.val()) != Ek
            || ((IROperand*)jNext.ops().get((u32)0)).kind() != (u8)OPK_USE
            || ((IROperand*)jNext.ops().get((u32)0)).val() != jPhi.res()
            || !ovConst((IROperand*)jNext.ops().get((u32)1), defOf, &jStep) || jStep != (i64)1)
            return false;

        IRInsn* kPhi = (IRInsn*)0;
        IRInsn* sPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < Hk.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)Hk.phis().get(i);
            if (p.res() != (IRValue*)0 && p.res() == ((IROperand*)gk.ops().get((u32)0)).val())
                kPhi = p;
            else
                sPhi = p;
            }
        if (kPhi == (IRInsn*)0 || sPhi == (IRInsn*)0 || sPhi.res() == (IRValue*)0 || sPhi.ops().count() != (u32)4)
            return false;
        String* laneTy = sPhi.res().ty();
        if (laneTy == (String*)0 || !(laneTy.equals(String.withCString("U32")) || laneTy.equals(String.withCString("I32"))
                                      || laneTy.equals(String.withCString("F32"))))
            return false;
        // The width this function may use: a dispatch clone's own level, else
        // the target's (vectorBytes). It was a fixed four lanes, which left
        // x86-64 at 128 bits under AVX-512 (bug 644).
        i64 lanes = (i64)(self.vectorBytes() / (u32)4);
        if (trip <= (i64)0 || trip % lanes != (i64)0)
            return false;
        IROperand* sInit = (IROperand*)0;
        IROperand* sBack = (IROperand*)0;
        for (u32 q = (u32)0; q + (u32)1 < (u32)4; q = q + (u32)2)
            {
            if (((IROperand*)sPhi.ops().get(q)).blk() == Bk)
                sBack = (IROperand*)sPhi.ops().get(q + (u32)1);
            else
                sInit = (IROperand*)sPhi.ops().get(q + (u32)1);
            }
        if (sInit == (IROperand*)0 || sBack == (IROperand*)0 || sBack.kind() != (u8)OPK_USE)
            return false;

        _ovRole = new Map();
        _ovRole.set((Hashable*)jPhi.res(), (Object*)Number.withU32((u32)1));
        _ovRole.set((Hashable*)sPhi.res(), (Object*)Number.withU32((u32)3));
        String* addrPre = String.withCString("Ptr(");
        addrPre.append(laneTy);
        addrPre.appendCString(",");
        Array* loadVals = new Array();
        Array* loadNames = new Array();
        Array* storeVals = new Array();
        Array* storeNames = new Array();
        u32 vecStores = (u32)0;
        for (u32 bi = (u32)0; bi < (u32)2; bi = bi + (u32)1)
            {
            IRBlock* blk = bi == (u32)0 ? Bk : Ek;
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)blk.insns().get(i);
                if (n == jNext)
                    continue;
                String* op = n.op();
                bool anyNon = false;
                for (u32 q = (u32)0; q < n.ops().count(); q = q + (u32)1)
                    if (ovRoleOf((IROperand*)n.ops().get(q)) != (u32)0)
                        anyNon = true;
                if (op.equals(String.withCString("Load")))
                    {
                    if (n.ops().count() < (u32)1 || ((IROperand*)n.ops().get((u32)0)).kind() != (u8)OPK_USE)
                        return false;
                    if (!ovAddRoot(((IROperand*)n.ops().get((u32)0)).val(), defOf, loadVals, loadNames))
                        return false;
                    u32 ar = ovRoleOf((IROperand*)n.ops().get((u32)0));
                    if (ar == (u32)0)
                        continue;
                    if (ar != (u32)2 || n.res() == (IRValue*)0 || n.res().ty() == (String*)0 || !n.res().ty().equals(laneTy))
                        return false;
                    _ovRole.set((Hashable*)n.res(), (Object*)Number.withU32((u32)3));
                    continue;
                    }
                if (op.equals(String.withCString("Store")))
                    {
                    if (blk != Ek || n.ops().count() < (u32)2 || ovRoleOf((IROperand*)n.ops().get((u32)0)) != (u32)2
                        || ovRoleOf((IROperand*)n.ops().get((u32)1)) != (u32)3
                        || ((IROperand*)n.ops().get((u32)0)).kind() != (u8)OPK_USE)
                        return false;
                    if (!ovAddRoot(((IROperand*)n.ops().get((u32)0)).val(), defOf, storeVals, storeNames))
                        return false;
                    vecStores = vecStores + (u32)1;
                    continue;
                    }
                if (n.res() == (IRValue*)0 || n.memRes() != (IRValue*)0)
                    return false;
                if (!anyNon)
                    continue;
                if (op.equals(String.withCString("Add")) && n.ops().count() == (u32)2)
                    {
                    u32 r0 = ovRoleOf((IROperand*)n.ops().get((u32)0));
                    u32 r1 = ovRoleOf((IROperand*)n.ops().get((u32)1));
                    if ((r0 == (u32)1 && r1 == (u32)0) || (r1 == (u32)1 && r0 == (u32)0))
                        {
                        _ovRole.set((Hashable*)n.res(), (Object*)Number.withU32((u32)1));
                        continue;
                        }
                    }
                if (op.equals(String.withCString("ElementAddr")) && n.ops().count() == (u32)2
                    && ovRoleOf((IROperand*)n.ops().get((u32)0)) == (u32)0 && ovRoleOf((IROperand*)n.ops().get((u32)1)) == (u32)1)
                    {
                    if (n.res().ty() == (String*)0 || !n.res().ty().hasPrefix(addrPre))
                        return false;
                    _ovRole.set((Hashable*)n.res(), (Object*)Number.withU32((u32)2));
                    continue;
                    }
                if (ovArith(op) && n.ops().count() == (u32)2 && n.res().ty() != (String*)0 && n.res().ty().equals(laneTy))
                    {
                    u32 r0 = ovRoleOf((IROperand*)n.ops().get((u32)0));
                    u32 r1 = ovRoleOf((IROperand*)n.ops().get((u32)1));
                    if ((r0 == (u32)3 || r0 == (u32)0) && (r1 == (u32)3 || r1 == (u32)0)
                        && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_USE
                        && ((IROperand*)n.ops().get((u32)1)).kind() == (u8)OPK_USE)
                        {
                        _ovRole.set((Hashable*)n.res(), (Object*)Number.withU32((u32)3));
                        continue;
                        }
                    }
                return false;
                }
            }
        if (vecStores == (u32)0 || ovRoleOf(sBack) != (u32)3 || (IRBlock*)defBlk.get((Hashable*)sBack.val()) != Bk)
            return false;
        for (u32 i = (u32)0; i < storeVals.count(); i = i + (u32)1)
            for (u32 k = (u32)0; k < loadVals.count(); k = k + (u32)1)
                if (storeVals.get(i) == loadVals.get(k))
                    return false;
        for (u32 i = (u32)0; i < storeNames.count(); i = i + (u32)1)
            for (u32 k = (u32)0; k < loadNames.count(); k = k + (u32)1)
                if (((String*)storeNames.get(i)).equals((String*)loadNames.get(k)))
                    return false;
        if (!ovUsesConfined(fn, Bk, Ek, jPhi, sPhi, gj, jNext))
            return false;
        ovRewrite(fn, Bj, Hk, Bk, Ek, jPhi, sPhi, jNext, sInit, sBack, laneTy, lanes);
        return true;
        }

    // No non-uniform value is read outside Bk / Ek (bar j's guard and step and
    // s's own phi); an index only as one, an address only by a load or store.
    final bool ovUsesConfined(IRFunc* fn, IRBlock* Bk, IRBlock* Ek, IRInsn* jPhi, IRInsn* sPhi, IRInsn* gj, IRInsn* jNext)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            bool inside = (bb == Bk || bb == Ek);
            u32 total = bb.phis().count() + bb.insns().count() + (u32)1;
            for (u32 i = (u32)0; i < total; i = i + (u32)1)
                {
                IRInsn* u = (IRInsn*)0;
                if (i < bb.phis().count())
                    u = (IRInsn*)bb.phis().get(i);
                else if (i < bb.phis().count() + bb.insns().count())
                    u = (IRInsn*)bb.insns().get(i - bb.phis().count());
                else
                    u = bb.term();
                if (u == (IRInsn*)0)
                    continue;
                for (u32 q = (u32)0; q < u.ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)u.ops().get(q);
                    u32 r = ovRoleOf(o);
                    if (r == (u32)0)
                        continue;
                    if (o.val() == jPhi.res() && (u == gj || u == jNext))
                        continue;
                    if (u == sPhi)
                        continue;
                    if (!inside)
                        return false;
                    if (r == (u32)1)
                        {
                        bool okIdx = (u.op().equals(String.withCString("Add")) && u.res() != (IRValue*)0
                                      && ovRoleOfVal(u.res()) == (u32)1)
                                  || (u.op().equals(String.withCString("ElementAddr")) && q == (u32)1);
                        if (!okIdx)
                            return false;
                        }
                    if (r == (u32)2 && !((u.op().equals(String.withCString("Load")) || u.op().equals(String.withCString("Store"))) && q == (u32)0))
                        return false;
                    }
                }
            }
        return true;
        }

    static String* ovVecOp(String* op)
        {
        // The vector ops are typed by their lanes: FAdd is VAdd on f32 lanes.
        if (op.equals(String.withCString("FAdd"))) return String.withCString("VAdd");
        if (op.equals(String.withCString("FSub"))) return String.withCString("VSub");
        if (op.equals(String.withCString("FMul"))) return String.withCString("VMul");
        String* v = String.withCString("V");
        v.append(op);
        return v;
        }

    // Splat of `o` in the block being rebuilt, made once per value.
    final IROperand* ovVecOperand(IROperand* o, Map* vmap, Map* splats, Array* nb, String* vecTy)
        {
        if (ovRoleOf(o) == (u32)3)
            return IROperand.useVal((IRValue*)vmap.get((Hashable*)o.val()));
        Object* have = splats.get((Hashable*)o.val());
        if (have == (Object*)0)
            {
            IRValue* sv = new IRValue(vecTy);
            IRInsn* si = IRInsn.with(String.withCString("VSplat"));
            si.setRes(sv);
            si.add(o);
            nb.add((Object*)si);
            splats.set((Hashable*)o.val(), (Object*)sv);
            have = (Object*)sv;
            }
        return IROperand.useVal((IRValue*)have);
        }

    final void ovRewrite(IRFunc* fn, IRBlock* Bj, IRBlock* Hk, IRBlock* Bk, IRBlock* Ek, IRInsn* jPhi, IRInsn* sPhi,
                   IRInsn* jNext, IROperand* sInit, IROperand* sBack, String* laneTy, i64 lanes)
        {
        String* vecTy = self.vecTyOf(laneTy, (u32)lanes * (u32)4);
        Map* vmap = new Map();
        IRValue* vInit = new IRValue(vecTy);
        IRInsn* vi = IRInsn.with(String.withCString("VSplat"));
        vi.setRes(vInit);
        vi.add(sInit);
        Bj.insns().add((Object*)vi);
        IRValue* vAcc = new IRValue(vecTy);
        vmap.set((Hashable*)sPhi.res(), (Object*)vAcc);
        for (u32 bi = (u32)0; bi < (u32)2; bi = bi + (u32)1)
            {
            IRBlock* blk = bi == (u32)0 ? Bk : Ek;
            Array* nb = new Array();
            Map* splats = new Map();
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)blk.insns().get(i);
                if (n == jNext)
                    {
                    n.ops().set((u32)1, (Object*)IROperand.immI((i32)lanes, jPhi.res().ty()));
                    nb.add((Object*)n);
                    continue;
                    }
                if (n.op().equals(String.withCString("Store")))
                    {
                    IRInsn* vs = IRInsn.with(String.withCString("VStore"));
                    vs.copyDbg(n);
                    for (u32 q = (u32)0; q < n.ops().count(); q = q + (u32)1)
                        {
                        if (q == (u32)1)
                            vs.add(ovVecOperand((IROperand*)n.ops().get(q), vmap, splats, nb, vecTy));
                        else
                            vs.add((IROperand*)n.ops().get(q));
                        }
                    vs.setMemRes(n.memRes());
                    vs.setRes(n.res());
                    nb.add((Object*)vs);
                    continue;
                    }
                if (n.res() == (IRValue*)0 || ovRoleOfVal(n.res()) != (u32)3)
                    {
                    nb.add((Object*)n);
                    continue;
                    }
                IRValue* vr = new IRValue(vecTy);
                if (n.op().equals(String.withCString("Load")))
                    {
                    IRInsn* vl = IRInsn.with(String.withCString("VLoad"));
                    vl.copyDbg(n);
                    vl.setRes(vr);
                    for (u32 q = (u32)0; q < n.ops().count(); q = q + (u32)1)
                        vl.add((IROperand*)n.ops().get(q));
                    vl.setMemRes(n.memRes());
                    nb.add((Object*)vl);
                    }
                else
                    {
                    IROperand* a = ovVecOperand((IROperand*)n.ops().get((u32)0), vmap, splats, nb, vecTy);
                    IROperand* b = ovVecOperand((IROperand*)n.ops().get((u32)1), vmap, splats, nb, vecTy);
                    IRInsn* va = IRInsn.with(ovVecOp(n.op()));
                    va.copyDbg(n);
                    va.setRes(vr);
                    va.add(a);
                    va.add(b);
                    nb.add((Object*)va);
                    }
                vmap.set((Hashable*)n.res(), (Object*)vr);
                }
            blk.setInsns(nb);
            }
        IRBlock* initBlk = ((IROperand*)sPhi.ops().get((u32)0)).blk() == Bk ? ((IROperand*)sPhi.ops().get((u32)2)).blk()
                                                                            : ((IROperand*)sPhi.ops().get((u32)0)).blk();
        IRInsn* vPhi = IRInsn.with(String.withCString("Phi"));
        vPhi.setRes(vAcc);
        vPhi.add(IROperand.block(initBlk));
        vPhi.add(IROperand.useVal(vInit));
        vPhi.add(IROperand.block(Bk));
        vPhi.add(IROperand.useVal((IRValue*)vmap.get((Hashable*)sBack.val())));
        for (u32 i = (u32)0; i < Hk.phis().count(); i = i + (u32)1)
            if ((IRInsn*)Hk.phis().get(i) == sPhi)
                {
                Hk.phis().set(i, (Object*)vPhi);
                break;
                }
        }
    }
