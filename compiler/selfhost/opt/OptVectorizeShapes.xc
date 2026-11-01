// OptVectorizeShapes.xc — the vectoriser recognising loops: reduction, dot, max/min, widening, count and escape-time shapes (XTIROptVectorize.m).
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptVectorizeParts>

    class Opt (VectorizeShapes)
    {

    // The item loop of a par body (ParImpl$<n>$run, from the block's lo to its
    // hi): its work items are independent by the language (par.md,
    // "Independent work items": none may read what another writes), so its
    // arrays need not be proved distinct. As the reference (parItemLoop).
    final bool escParItemLoop(void)
        {
        String* nm = _esFn.name();
        if (!nm.hasPrefix(String.withCString("ParImpl$")) || !nm.hasSuffix(String.withCString("$run")) || _esBoundConst)
            return false;
        return self.escIsParField(escFrom(_esIvPhi, _esPH), (i64)1) && self.escIsParField(_esBoundOp, (i64)2);
        }

    // H: `iv < N` over a phi stepping by one, N a constant; PH enters it by
    // an unconditional branch, and its true edge goes to B.
    final bool escOuter(IRFunc* fn)
        {
        IRBlock* H = _esH;
        IRInsn* term = H.term();
        if (!Opt.escIs(term, "CondBranch") || term.ops().count() < (u32)3)
            return false;
        IROperand* co = (IROperand*)term.ops().get((u32)0);
        if (co.kind() != (u8)OPK_USE)
            return false;
        IRInsn* g = (IRInsn*)_esDefOf.get((Hashable*)co.val());
        if (!Opt.escIs(g, "ICmp") || g.ops().count() < (u32)2 || g.pred() == (String*)0)
            return false;
        bool ult = g.pred().equals(String.withCString("ULT"));
        if (!ult && !g.pred().equals(String.withCString("SLT")))
            return false;
        _esSigned = !ult;
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            if (n != g && !Opt.escIs(n, "Const"))
                return false;
            }
        IROperand* g0 = (IROperand*)g.ops().get((u32)0);
        if (g0.kind() != (u8)OPK_USE)
            return false;
        // The bound: a constant, or a value from outside the loop (checked once
        // the loop's blocks are known, in escRecognise).
        i32 nk = (i32)0;
        _esBoundOp = (IROperand*)g.ops().get((u32)1);
        _esBoundConst = vecConst(_esBoundOp, _esDefOf, &nk);
        _esN = (i64)nk;
        if (!_esBoundConst && (_esBoundOp.kind() != (u8)OPK_USE || _esBoundOp.val() == g0.val()))
            return false;
        _esB = ((IROperand*)term.ops().get((u32)1)).blk();
        _esX = ((IROperand*)term.ops().get((u32)2)).blk();
        if (_esB == H || _esX == H)
            return false;
        Array* ps = self.escPreds(fn, H);
        if (ps.count() != (u32)2)
            return false;
        _esIvPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == g0.val())
                _esIvPhi = p;
            }
        if (_esIvPhi == (IRInsn*)0 || !Opt.escLane32(_esIvPhi.res().ty()) || _esIvPhi.res().ty().equals(String.withCString("F32")))
            return false;
        // The latch is the predecessor whose value is iv + 1; the other enters.
        IRBlock* p0 = (IRBlock*)ps.get((u32)0);
        IRBlock* p1 = (IRBlock*)ps.get((u32)1);
        IROperand* b0 = Opt.escFrom(_esIvPhi, p0);
        bool firstIsLatch = b0 != (IROperand*)0 && b0.kind() == (u8)OPK_USE
                         && Opt.escIs((IRInsn*)_esDefOf.get((Hashable*)b0.val()), "Add")
                         && self.escBlockOf(fn, b0.val()) == p0;
        _esE = firstIsLatch ? p0 : p1;
        _esPH = firstIsLatch ? p1 : p0;
        if (_esE == _esB || _esPH == _esB || !Opt.escIs(_esPH.term(), "Branch"))
            return false;
        return self.escPreds(fn, _esB).count() == (u32)1 && _esB.phis().count() == (u32)0
            && Opt.escIs(_esB.term(), "Branch");
        }

    final bool escExitBlock(IRFunc* fn)
        {
        if (!Opt.escIs(_esE.term(), "Branch") || ((IROperand*)_esE.term().ops().get((u32)0)).blk() != _esH)
            return false;
        IRValue* iv = _esIvPhi.res();
        IROperand* ivBack = Opt.escFrom(_esIvPhi, _esE);
        if (ivBack == (IROperand*)0 || ivBack.kind() != (u8)OPK_USE)
            return false;
        _esIvNext = (IRInsn*)_esDefOf.get((Hashable*)ivBack.val());
        if (!Opt.escIs(_esIvNext, "Add") || _esIvNext.ops().count() != (u32)2 || self.escBlockOf(fn, ivBack.val()) != _esE)
            return false;
        IROperand* a = (IROperand*)_esIvNext.ops().get((u32)0);
        IROperand* b = (IROperand*)_esIvNext.ops().get((u32)1);
        i32 one = (i32)0;
        IROperand* step = a.kind() == (u8)OPK_USE && a.val() == iv ? b : a;
        IROperand* self0 = a.kind() == (u8)OPK_USE && a.val() == iv ? a : b;
        if (self0.kind() != (u8)OPK_USE || self0.val() != iv || !vecConst(step, _esDefOf, &one) || one != (i32)1)
            return false;
        Set* special = new Set();
        special.add((Hashable*)_esIvNext.res());
        _esAccPhis = new Array();
        _esAccW = new Array();
        _esAccKind = new Array();
        _esAccCond = new Array();
        _esPassPhis = new Array();
        for (u32 i = (u32)0; i < _esH.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)_esH.phis().get(i);
            if (p == _esIvPhi)
                continue;
            // A phi the loop leaves as it is (its back value itself; xc's
            // slot for an earlier loop's variable): it re-enters unchanged.
            IROperand* pb = Opt.escFrom(p, _esE);
            if (pb != (IROperand*)0 && pb.kind() == (u8)OPK_USE && pb.val() == p.res() && p.ops().count() == (u32)4
                && self.escUses(p.res()) == (u32)1)
                {
                _esPassPhis.add((Object*)p);
                continue;
                }
            if (!self.escAccOf(fn, p, special))
                return false;
            }
        // ONE store of a lane value to a[i]: the lanes' stores are disjoint and
        // in order; a second could alias the first across lanes.
        _esStoreAddr = (IRInsn*)0;
        _esStore = (IRInsn*)0;
        for (u32 i = (u32)0; i < _esE.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)_esE.insns().get(i);
            if (!Opt.escIs(n, "Store"))
                continue;
            if (_esStore != (IRInsn*)0 || n.ops().count() < (u32)2)
                return false;
            IROperand* ad = (IROperand*)n.ops().get((u32)0);
            IRInsn* ea = ad.kind() == (u8)OPK_USE ? (IRInsn*)_esDefOf.get((Hashable*)ad.val()) : (IRInsn*)0;
            if (!Opt.escIs(ea, "ElementAddr") || ea.ops().count() != (u32)2 || self.escBlockOf(fn, ea.res()) != _esE
                || self.escUses(ea.res()) != (u32)1)
                return false;
            IROperand* ix = (IROperand*)ea.ops().get((u32)1);
            if (ix.kind() != (u8)OPK_USE || ix.val() != iv || ((IROperand*)ea.ops().get((u32)0)).kind() != (u8)OPK_USE)
                return false;
            _esStore = n;
            _esStoreAddr = ea;
            special.add((Hashable*)ea.res());
            }
        _esELane = new Array();
        for (u32 i = (u32)0; i < _esE.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)_esE.insns().get(i);
            if (escIs(n, "Const") || n == _esStore || (n.res() != (IRValue*)0 && special.contains((Hashable*)n.res())))
                continue;
            _esELane.add((Object*)n);
            }
        return true;
        }

    // A load's address: 1 a[i] (i the pixel iv: a vector load), 2 a[j] (j a
    // phi of T0: one load for every lane, valid only when all run the same
    // trips), 3 from outside the loop or a[c] (one load). 0 when none of them.
    final u32 escAddrKind(IRInsn* ea)
        {
        if (!Opt.escIs(ea, "ElementAddr") || ea.ops().count() != (u32)2)
            return (u32)0;
        IROperand* base = (IROperand*)ea.ops().get((u32)0);
        IROperand* ix = (IROperand*)ea.ops().get((u32)1);
        if (base.kind() != (u8)OPK_USE || !self.escIsInvariant(base.val()))
            return (u32)0;
        if (ix.kind() == (u8)OPK_IMMI)
            return (u32)3;
        if (ix.kind() != (u8)OPK_USE)
            return (u32)0;
        if (ix.val() == _esIvPhi.res())
            return (u32)1;
        for (u32 i = (u32)0; i < _esT0.phis().count(); i = i + (u32)1)
            if (((IRInsn*)_esT0.phis().get(i)).res() == ix.val())
                return (u32)2;
        return self.escIsInvariant(ix.val()) ? (u32)3 : (u32)0;
        }

    final bool escLoadOK(IRInsn* n)
        {
        if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0 || !Opt.escLane32(n.res().ty()))
            return false;
        IROperand* ad = (IROperand*)n.ops().get((u32)0);
        if (ad.kind() != (u8)OPK_USE)
            return false;
        IRInsn* ea = self.escOwnAddr(ad);
        if (ea != (IRInsn*)0)
            {
            u32 k = escAddrKind(ea);
            if (k == (u32)0)
                return false;
            if (k == (u32)2)
                _esIdxPhis.add((Hashable*)((IROperand*)ea.ops().get((u32)1)).val());
            _esLoadRoots.add((Hashable*)self.escRootOf(((IROperand*)ea.ops().get((u32)0)).val()));
            return true;
            }
        if (!self.escIsInvariant(ad.val()))
            return false;
        _esLoadRoots.add((Hashable*)self.escRootOf(ad.val()));
        return true;
        }

    // The loop's own address arithmetic: read by its loads alone.
    final bool escAddrOK(IRInsn* n)
        {
        if (escAddrKind(n) == (u32)0)
            return false;
        u32 loads = (u32)0;
        Array* blks = self.escRegionBlocks();
        blks.add((Object*)_esE);
        for (u32 b = (u32)0; b < blks.count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)blks.get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* m = (IRInsn*)bb.insns().get(i);
                if (escIs(m, "Load") && m.ops().count() >= (u32)1)
                    {
                    IROperand* o = (IROperand*)m.ops().get((u32)0);
                    if (o.kind() == (u8)OPK_USE && o.val() == n.res())
                        loads = loads + (u32)1;
                    }
                }
            }
        return loads == self.escUses(n.res());
        }

    // A shift count or divisor that is a constant: its value, else -1.
    final i64 escConstOf(IROperand* o)
        {
        i32 k = (i32)0;
        if (!vecConst(o, _esDefOf, &k))
            return (i64)0 - (i64)1;
        return (i64)k;
        }

    // A value proved in [0, 2^31), so a signed conversion of it is exact
    // whatever its type says: a remainder or a quotient by a constant, a
    // right shift, or an And with a small mask.
    final bool escSmallUnsigned(IROperand* o)
        {
        if (o.kind() != (u8)OPK_USE)
            return false;
        IRInsn* d = (IRInsn*)_esDefOf.get((Hashable*)o.val());
        if (d == (IRInsn*)0 || d.ops().count() < (u32)2)
            return false;
        i64 k = escConstOf((IROperand*)d.ops().get((u32)1));
        if (escIs(d, "URem"))
            return k > (i64)0 && k <= (i64)$80000000;
        if (escIs(d, "UDiv"))
            return k >= (i64)2;
        if (escIs(d, "LShr"))
            return k >= (i64)1 && k < (i64)32;
        if (escIs(d, "And"))
            return k >= (i64)0 && k <= (i64)$7FFFFFFF;
        return false;
        }

    // `(u32)100`: a ZExt/SExt/Trunc of a constant, which is itself a constant.
    final bool escIsConstExt(IRInsn* n)
        {
        if (n == (IRInsn*)0 || n.res() == (IRValue*)0)
            return false;
        if (!(Opt.escIs(n, "ZExt") || Opt.escIs(n, "SExt") || Opt.escIs(n, "Trunc")))
            return false;
        // Of any integer width, as a Const is: a shift amount is a u8, and a
        // constant is only read through a splat or as the shift's own
        // immediate. As the reference.
        i32 k = (i32)0;
        String* rt = n.res().ty();
        bool intTy = rt.equals(String.withCString("U8")) || rt.equals(String.withCString("I8"))
                  || rt.equals(String.withCString("U16")) || rt.equals(String.withCString("I16")) || Opt.escLane32(rt);
        return intTy && !rt.equals(String.withCString("F32"))
            && vecConst(IROperand.useVal(n.res()), _esDefOf, &k);
        }

    // The splat of an invariant or an immediate, made once in PH. A constant
    // defined inside the loop is copied there first.
    final IRValue* escSplatOf(IROperand* o, String* scalarTy)
        {
        Array* pre = _esSplatTo;
        if (o.kind() == (u8)OPK_USE)
            {
            Object* have = _esFresh ? (Object*)0 : _esSplat.get((Hashable*)o.val());
            if (have != (Object*)0)
                return (IRValue*)have;
            IROperand* src = o;
            IRInsn* d = (IRInsn*)_esDefOf.get((Hashable*)o.val());
            if (d != (IRInsn*)0 && (Opt.escIs(d, "Const") || escIsConstExt(d)))
                {
                IRValue* cv = new IRValue(o.val().ty());
                IRInsn* c = IRInsn.with(String.withCString("Const"));
                c.setRes(cv);
                if (escIs(d, "Const"))
                    c.add((IROperand*)d.ops().get((u32)0));
                else
                    {
                    i32 k = (i32)0;
                    vecConst(o, _esDefOf, &k);
                    c.add(IROperand.immI((i64)k, o.val().ty()));
                    }
                pre.add((Object*)c);
                src = IROperand.useVal(cv);
                }
            IRValue* s = self.escPut(pre, "VSplat", self.escVecTy(o.val().ty()), src, (IROperand*)0);
            if (!_esFresh)
                _esSplat.set((Hashable*)o.val(), (Object*)s);
            return s;
            }
        IRValue* cv = new IRValue(scalarTy);
        IRInsn* c = IRInsn.with(String.withCString("Const"));
        c.setRes(cv);
        c.add(o);
        pre.add((Object*)c);
        return self.escPut(pre, "VSplat", self.escVecTy(scalarTy), IROperand.useVal(cv), (IROperand*)0);
        }

    // A load: a[i] is a vector load at a[viv]; a[j] (j the trip count) and an
    // address from outside the loop are one scalar load, splat across lanes.
    // The memory token is the function's own: tokens order, they do not name
    // storage, and the loop's own ones are not defined in the vector loop.
    final void escLaneLoad(Array* into, IRInsn* n)
        {
        IROperand* ad = (IROperand*)n.ops().get((u32)0);
        IRInsn* ea = self.escOwnAddr(ad);
        u32 kind = ea != (IRInsn*)0 ? escAddrKind(ea) : (u32)3;
        String* vty = self.escVecTy(n.res().ty());
        IRValue* r = (IRValue*)0;
        if (kind == (u32)1)
            {
            IRValue* av = new IRValue(ea.res().ty());
            IRInsn* e2 = IRInsn.with(String.withCString("ElementAddr"));
            e2.setRes(av);
            e2.add((IROperand*)ea.ops().get((u32)0));
            e2.add(IROperand.useVal(_esViv));
            into.add((Object*)e2);
            r = self.escPut(into, "VLoad", vty, IROperand.useVal(av), (IROperand*)0);
            }
        else
            {
            IROperand* addr = ad;
            if (ea != (IRInsn*)0)
                {
                IRValue* av = new IRValue(ea.res().ty());
                IRInsn* e2 = IRInsn.with(String.withCString("ElementAddr"));
                e2.setRes(av);
                e2.add((IROperand*)ea.ops().get((u32)0));
                e2.add(kind == (u32)2 ? IROperand.useVal(_esTripV) : (IROperand*)ea.ops().get((u32)1));
                into.add((Object*)e2);
                addr = IROperand.useVal(av);
                }
            IRValue* sv = new IRValue(n.res().ty());
            IRInsn* ld = IRInsn.with(String.withCString("Load"));
            ld.setRes(sv);
            ld.add(addr);
            ld.add(IROperand.useVal((IRValue*)_esFn.params().get(_esFn.params().count() - (u32)1)));
            ld.setMemRes(new IRValue(String.withCString("Mem")));
            into.add((Object*)ld);
            r = self.escPut(into, "VSplat", vty, IROperand.useVal(sv), (IROperand*)0);
            }
        _esMap.set((Hashable*)n.res(), (Object*)r);
        ((IRInsn*)into.get(into.count() - (u32)1)).copyDbg(n);
        }

    // The originals in order, then each copy's run in turn: a copy's own
    // instructions stay next to each other, which is what lets the back end
    // still fuse a lane multiply into the add that takes it.
    final void escJamInsns(IRBlock* b, Array* maps, Set* D, IRValue* skip, Array* lead)
        {
        Array* out = new Array();
        for (u32 i = (u32)0; i < lead.count(); i = i + (u32)1)
            out.add(lead.get(i));
        Array* lane = new Array();
        for (u32 i = (u32)0; i < b.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)b.insns().get(i);
            out.add((Object*)n);
            if ((skip != (IRValue*)0 && n.res() == skip) || !Opt.escJamUses(n, D))
                continue;
            if (n.res() != (IRValue*)0)
                D.add((Hashable*)n.res());
            if (n.memRes() != (IRValue*)0)
                D.add((Hashable*)n.memRes());
            lane.add((Object*)n);
            }
        for (u32 u = (u32)0; u < maps.count(); u = u + (u32)1)
            for (u32 i = (u32)0; i < lane.count(); i = i + (u32)1)
                out.add((Object*)self.vecCloneInsn((IRInsn*)lane.get(i), (Map*)maps.get(u), new Map()));
        b.setInsns(out);
        }

    final void escJam(IRBlock* VB, IRBlock* VI, IRBlock* VE, IRValue* viv, IRValue* vivNext)
        {
        Array* maps = new Array();
        Set* D = new Set();
        D.add((Hashable*)viv);
        Array* lead = new Array();
        for (u32 u = (u32)1; u < _esJam; u = u + (u32)1)
            {
            IRValue* vu = self.escPut(lead, "Add", viv.ty(), IROperand.useVal(viv), IROperand.immI((i64)(u * _esVF), viv.ty()));
            Map* m = new Map();
            m.set((Hashable*)viv, (Object*)vu);
            maps.add((Object*)m);
            }
        escJamInsns(VB, maps, D, (IRValue*)0, lead);
        // VI's lane phis: their copies' results first, so the body's copies
        // can name them; their operands once the body is copied.
        Array* lanePhis = new Array();
        Array* phiRes = new Array();
        for (u32 i = (u32)0; i < VI.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)VI.phis().get(i);
            if (p.res() == (IRValue*)0 || !(p.res().ty().hasPrefix(String.withCString("Vec(")) || Opt.escJamUses(p, D)))
                continue;
            D.add((Hashable*)p.res());
            Array* rs = new Array();
            for (u32 u = (u32)0; u < maps.count(); u = u + (u32)1)
                {
                IRValue* r = new IRValue(p.res().ty());
                ((Map*)maps.get(u)).set((Hashable*)p.res(), (Object*)r);
                rs.add((Object*)r);
                }
            lanePhis.add((Object*)p);
            phiRes.add((Object*)rs);
            }
        escJamInsns(VI, maps, D, (IRValue*)0, new Array());
        Array* phis = new Array();
        for (u32 i = (u32)0; i < VI.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)VI.phis().get(i);
            phis.add((Object*)p);
            u32 k = (u32)0;
            bool found = false;
            for (u32 j = (u32)0; j < lanePhis.count(); j = j + (u32)1)
                if ((IRInsn*)lanePhis.get(j) == p)
                    {
                    k = j;
                    found = true;
                    }
            if (!found)
                continue;
            for (u32 u = (u32)0; u < maps.count(); u = u + (u32)1)
                {
                IRInsn* c = IRInsn.with(String.withCString("Phi"));
                c.setRes((IRValue*)((Array*)phiRes.get(k)).get(u));
                for (u32 q = (u32)0; q < p.ops().count(); q = q + (u32)1)
                    c.add(self.vecSubst((Map*)maps.get(u), new Map(), (IROperand*)p.ops().get(q)));
                phis.add((Object*)c);
                }
            }
        VI.setPhis(phis);
        escJamInsns(VE, maps, D, vivNext, new Array());
        }

    final void escTripTest(void)
        {
        _esTripTest = (i32)0 - (i32)1;
        _esTripPhi = (IRInsn*)0;
        for (u32 t = (u32)0; t < _esTests.count(); t = t + (u32)1)
            {
            if (((Number*)_esCont.get(t)).asU32() != (u32)1)
                continue;
            IRBlock* T = (IRBlock*)_esTests.get(t);
            IROperand* co = (IROperand*)T.term().ops().get((u32)0);
            IRInsn* g = (IRInsn*)_esDefOf.get((Hashable*)co.val());
            // `k < N && rest`, if-converted to an And: the trip count takes the
            // `k < N` half and the rest stays a lane test.
            _esTripAnd = (IRInsn*)0;
            _esTripOther = (IROperand*)0;
            if (escIs(g, "And") && g.ops().count() == (u32)2 && self.escUses(g.res()) == (u32)1
                && _esRegion.contains((Hashable*)g.res()))
                {
                IRInsn* andI = g;
                g = (IRInsn*)0;
                for (u32 h = (u32)0; h < (u32)2 && g == (IRInsn*)0; h = h + (u32)1)
                    {
                    IROperand* side = (IROperand*)andI.ops().get(h);
                    IROperand* other = (IROperand*)andI.ops().get((u32)1 - h);
                    if (side.kind() != (u8)OPK_USE || other.kind() != (u8)OPK_USE)
                        continue;
                    IRInsn* q = (IRInsn*)_esDefOf.get((Hashable*)side.val());
                    if (escIs(q, "ICmp") && self.escTripCmpOK(q, true))
                        {
                        g = q;
                        _esTripAnd = andI;
                        _esTripOther = other;
                        }
                    }
                if (g == (IRInsn*)0)
                    continue;
                }
            else if (!Opt.escIs(g, "ICmp") || !self.escTripCmpOK(g, false) || self.escBlockOf(_esFn, g.res()) != T)
                continue;
            bool ult = g.pred().equals(String.withCString("ULT"));
            if (!ult && !g.pred().equals(String.withCString("SLT")))
                continue;
            IROperand* k = (IROperand*)g.ops().get((u32)0);
            i32 n = (i32)0;
            i32 c0 = (i32)0;
            if (k.kind() != (u8)OPK_USE || !vecConst((IROperand*)g.ops().get((u32)1), _esDefOf, &n))
                continue;
            IRInsn* p = (IRInsn*)0;
            for (u32 i = (u32)0; i < _esT0.phis().count(); i = i + (u32)1)
                if (((IRInsn*)_esT0.phis().get(i)).res() == k.val())
                    p = (IRInsn*)_esT0.phis().get(i);
            if (p == (IRInsn*)0 || escCounterOf(p) == (IRInsn*)0 || !vecConst(escFrom(p, _esB), _esDefOf, &c0))
                continue;
            bool below = ult ? (u32)c0 < (u32)n : c0 < n;
            if (!below)
                continue;
            _esTripTest = (i32)t;
            _esTripPhi = p;
            _esTripN = ult ? (i64)(u32)n : (i64)n;
            _esTripC0 = ult ? (i64)(u32)c0 : (i64)c0;
            _esTripTy = p.res().ty();
            _esTripSigned = !ult;
            _esSkip.add((Hashable*)g.res());
            if (_esTripAnd != (IRInsn*)0)
                _esSkip.add((Hashable*)_esTripAnd.res());
            return;
            }
        }

    // The `p + 1` in L that is T0 phi p's next value and read by nothing else,
    // p an integer: 0 if p is not such a counter.
    final IRInsn* escCounterOf(IRInsn* p)
        {
        if (p.res().ty().equals(String.withCString("F32")))
            return (IRInsn*)0;
        IROperand* back = Opt.escFrom(p, _esL);
        if (back == (IROperand*)0 || back.kind() != (u8)OPK_USE)
            return (IRInsn*)0;
        IRInsn* d = (IRInsn*)_esDefOf.get((Hashable*)back.val());
        if (!Opt.escIs(d, "Add") || d.ops().count() != (u32)2 || self.escBlockOf(_esFn, d.res()) != _esL)
            return (IRInsn*)0;
        IROperand* a = (IROperand*)d.ops().get((u32)0);
        IROperand* b = (IROperand*)d.ops().get((u32)1);
        IROperand* step = (a.kind() == (u8)OPK_USE && a.val() == p.res()) ? b : a;
        IROperand* self0 = (a.kind() == (u8)OPK_USE && a.val() == p.res()) ? a : b;
        i32 one = (i32)0;
        if (self0.kind() != (u8)OPK_USE || self0.val() != p.res() || !vecConst(step, _esDefOf, &one) || one != (i32)1)
            return (IRInsn*)0;
        if (escUses(d.res()) != (u32)1)
            return (IRInsn*)0;
        return d;
        }

    // Split out for the arm64 frame budget, as vecWideningAt was.
    final bool vecReassociateIn(IRFunc* fn, IRBlock* B, Map* accs)
        {
        bool changed = false;
        Map* uses = self.useCounts(fn);
        for (u32 oi = (u32)0; oi < B.insns().count(); oi = oi + (u32)1)
            {
            IRInsn* outer = (IRInsn*)B.insns().get(oi);
            if (!outer.op().equals(String.withCString("Add")) || outer.res() == (IRValue*)0
                || outer.ops().count() < (u32)2)
                continue;
            // The accumulator must not already be a direct operand.
            bool direct = false;
            for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
                {
                IROperand* o = (IROperand*)outer.ops().get(k);
                if (o.kind() == (u8)OPK_USE && accs.get((Hashable*)o.val()) != (Object*)0)
                    direct = true;
                }
            if (direct)
                continue;
            for (u32 side = (u32)0; side < (u32)2; side = side + (u32)1)
                {
                IROperand* spine = (IROperand*)outer.ops().get(side);
                IROperand* other = (IROperand*)outer.ops().get((u32)1 - side);
                if (spine.kind() != (u8)OPK_USE || self.countOf(uses, spine.val()) != (u32)1)
                    continue;
                u32 ii = oi;
                bool found = false;
                for (u32 k = (u32)0; k < oi; k = k + (u32)1)
                    if (((IRInsn*)B.insns().get(k)).res() == spine.val())
                        { ii = k; found = true; }
                if (!found)
                    continue;
                IRInsn* inner = (IRInsn*)B.insns().get(ii);
                if (!inner.op().equals(String.withCString("Add")) || inner.ops().count() < (u32)2)
                    continue;
                u32 accSide = (u32)2;
                for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)inner.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && accs.get((Hashable*)o.val()) != (Object*)0)
                        accSide = k;
                    }
                if (accSide == (u32)2)
                    continue;
                IROperand* accOp = (IROperand*)inner.ops().get(accSide);
                IROperand* x = (IROperand*)inner.ops().get((u32)1 - accSide);

                // inner becomes X + Y, keeping its result — its only user is
                // outer — and outer becomes acc + that.
                //
                // It must also MOVE to just before outer. Y is normally
                // computed AFTER the inner Add (it is the next term of the
                // expression), so rewriting inner where it stands would read Y
                // before it is defined. That is not a crash: the register holds
                // whatever was there, and int_muldiv came back 837576896
                // instead of 2079322496 — fast and wrong. Moving it down is
                // safe because X precedes inner and Y precedes outer, so both
                // dominate the new position.
                inner.ops().set((u32)0, (Object*)x);
                inner.ops().set((u32)1, (Object*)other);
                outer.ops().set((u32)0, (Object*)accOp);
                outer.ops().set((u32)1, (Object*)IROperand.useVal(spine.val()));
                B.insns().removeAt(ii);
                B.insns().insert(oi - (u32)1, (Object*)inner);
                changed = true;
                break;
                }
            }
        return changed;
        }

    // Remove one accumulator's phi and back-edge definition from a loop, then
    // sweep whatever that orphans out of the body. The cycle is closed, so
    // nothing else can refer to either once the uses outside have been
    // rewritten.
    final void vecDropAcc(IRFunc* fn, IRValue* acc, IRBlock* H, IRBlock* B)
        {
        IRValue* back = (IRValue*)0;
        Array* keptPhis = new Array();
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* phi = (IRInsn*)H.phis().get(i);
            if (phi.res() == acc && phi.ops().count() == (u32)4)
                {
                IROperand* bo = self.vecBackOp(phi, B);
                if (bo != (IROperand*)0 && bo.kind() == (u8)OPK_USE)
                    back = bo.val();
                continue;
                }
            keptPhis.add((Object*)phi);
            }
        H.setPhis(keptPhis);

        Array* kept = new Array();
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n.res() != (IRValue*)0 && n.res() == back)
                continue;
            kept.add((Object*)n);
            }
        B.setInsns(kept);

        // Sweep the orphans to a fixpoint: removing one can orphan the one
        // behind it.
        bool removed = true;
        while (removed)
            {
            removed = false;
            Map* uses = self.useCounts(fn);
            Array* keep = new Array();
            for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)B.insns().get(i);
                if (n.res() != (IRValue*)0 && n.memRes() == 0 && self.countOf(uses, n.res()) == (u32)0)
                    {
                    removed = true;
                    continue;
                    }
                keep.add((Object*)n);
                }
            B.setInsns(keep);
            }
        }

    // Point the vector loop's guard at its new limit: the runtime M computed in
    // the preheader, or the folded constant. EXTRACTED for the arm64 frame
    // budget -- inline, vecApplyMap needed 16640 bytes against 16384.
    final void vecMapSetBound(VecCand* c)
        {
        if (c.rtTrip())
            {
            _vecMapRtM = self.vecRuntimeLimit(c, c.pre());
            c.guard().ops().set((u32)1, (Object*)IROperand.useVal(_vecMapRtM));
            }
        else
            {
            _vecMapRtM = (IRValue*)0;
            c.guard().ops().set((u32)1, (Object*)IROperand.immI(c.epiM(), c.iv().ty()));
            }
        }

    final bool vecReduxShape(IRBlock* H, Map* defOf, Map* defBlk)
        {
        _vrIvPhi = (IRInsn*)0;
        _vrAccPhi = (IRInsn*)0;
        _vrGuard = (IRInsn*)0;
        _vrIv = (IRValue*)0;
        _vrB = (IRBlock*)0;
        _vrE = (IRBlock*)0;
        _vrN = (i64)0;
        _vrIvStart = (i64)-1;
        _vrIvStartOp = (IROperand*)0;
        _vrRuntime = false;
        _vrMapRT = false;
        _vrBoundOp = (IROperand*)0;
        // _vrAllowRT is deliberately NOT reset here: it is the CALLER's one-shot
        // opt-in, set immediately before this call, and clearing it at the top
        // of the routine it gates would wipe it before the bound check reads it.
        // It is cleared below instead, on both paths.
        if (H.phis().count() != (u32)2)
            return false; // induction + accumulator
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            if (((IRInsn*)H.insns().get(i)).memRes() != (IRValue*)0)
                return false;

        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE)
            return false;
        Object* go = defOf.get((Hashable*)c0.val());
        Object* gb = defBlk.get((Hashable*)c0.val());
        if (go == (Object*)0 || gb == (Object*)0 || (IRBlock*)gb != H)
            return false;
        IRInsn* guard = (IRInsn*)go;
        if (!guard.op().equals(String.withCString("ICmp")) || guard.ops().count() < (u32)2)
            return false;
        IROperand* gl = (IROperand*)guard.ops().get((u32)0);
        if (gl.kind() != (u8)OPK_USE)
            return false;
        IRValue* iv = gl.val();

        // The guarded value is the induction phi; the other phi is the carry.
        IRInsn* ivPhi = (IRInsn*)0;
        IRInsn* accPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0)
                return false;
            if (p.res() == iv)
                ivPhi = p;
            else
                accPhi = p;
            }
        if (ivPhi == (IRInsn*)0 || accPhi == (IRInsn*)0)
            return false;
        // The bound may be a literal or a RUNTIME value, recorded rather than
        // decided here: this routine is shared by the reduction, widening-sum
        // and dot-product recognisers, and only the reduction opts in (via
        // _vrAllowRT). The predicate check and the invariance check are the
        // caller's, keeping this routine's frame cost at zero new locals.
        i64 n = (i64)0;
        _vrRuntime = false;
        _vrBoundOp = (IROperand*)guard.ops().get((u32)1);
        if (!self.vecConstWide(_vrBoundOp, defOf, &n))
            {
            if (!_vrAllowRT)
                {
                _vrAllowRT = false;
                return false;
                }
            _vrAllowRT = false;
            if (_vrBoundOp.kind() != (u8)OPK_USE)
                return false;
            _vrRuntime = true;
            }
        else
            {
            _vrAllowRT = false;
            if (n <= (i32)0)
                return false;
            }

        IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
        IRBlock* B = (IRBlock*)0;
        IRBlock* E = (IRBlock*)0;
        if (rotIsLatch(t0, H))
            {
            B = t0;
            E = t1;
            }
        else if (rotIsLatch(t1, H))
            {
            B = t1;
            E = t0;
            }
        else
            return false;
        if (E == (IRBlock*)0 || B.insns().count() == (u32)0)
            return false;
        // The horizontal reduce goes at the top of E. A phi there referencing the
        // accumulator on the H→E edge would have to be rewired to a value defined
        // LATER in E, which is not valid SSA — so an exit phi refuses.
        if (E.phis().count() != (u32)0)
            return false;
        if (ivPhi.ops().count() != (u32)4 || accPhi.ops().count() != (u32)4)
            return false;

        _vrIvPhi = ivPhi;
        _vrAccPhi = accPhi;
        _vrGuard = guard;
        _vrIv = iv;
        _vrB = B;
        _vrE = E;
        _vrN = n;
        // Computed ONCE here rather than called from each recogniser: the call's
        // operands and result each claim a frame slot, and vecWideningAt is
        // already within 80 bytes of the arm64 frame budget.
        _vrIvStart = self.vecIvStart(ivPhi, B, defOf);
        return true;
        }

    // Classify every body instruction, returning the consistent lane type or
    // null if anything disqualifies the loop. Allowed: AddrOf, ElementAddr at
    // the iv over a loop-invariant base, Load/Store through such an address,
    // elementwise arithmetic, and the scalar plumbing (Const and the width
    // casts). Anything else — a call, a shifted load, a value that varies per
    // lane — refuses.
    final String* vecClassifyBody(IRBlock* B, IRValue* iv, IRInsn* ivNext,
                            Map* defOf, Map* defBlk)
        {
        String* laneTy = (String*)0;
        bool sawLoad = false;
        bool sawStore = false;
        // The elementwise set: results of iv-indexed loads and of elementwise
        // arithmetic over them. An operand must be in this set, or be a
        // loop-invariant scalar that is safe to broadcast — which is what
        // rejects `b[i] * i`, where the multiplier differs per lane.
        Array* elems = new Array();
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == ivNext)
                continue;
            String* op = n.op();
            if (op.equals(String.withCString("AddrOf")))
                continue;
            if (op.equals(String.withCString("ElementAddr")))
                {
                if (n.ops().count() < (u32)2)
                    return (String*)0;
                IROperand* idx = (IROperand*)n.ops().get((u32)1);
                if (idx.kind() != (u8)OPK_USE || idx.val() != iv)
                    return (String*)0;
                IROperand* base = (IROperand*)n.ops().get((u32)0);
                if (base.kind() == (u8)OPK_USE)
                    {
                    Object* db = defBlk.get((Hashable*)base.val());
                    if (db != (Object*)0 && (IRBlock*)db == B)
                        {
                        Object* bd = defOf.get((Hashable*)base.val());
                        if (bd == (Object*)0 || !((IRInsn*)bd).op().equals(String.withCString("AddrOf")))
                            return (String*)0;
                        }
                    }
                continue;
                }
            if (op.equals(String.withCString("Load")))
                {
                if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0)
                    return (String*)0;
                if (!self.vecIsElemAddr((IROperand*)n.ops().get((u32)0), iv, defOf))
                    return (String*)0;
                String* lt = n.res().ty();
                if (!self.vecLaneOK(lt))
                    return (String*)0;
                if (laneTy != (String*)0 && !laneTy.equals(lt))
                    return (String*)0;
                laneTy = lt;
                sawLoad = true;
                elems.add((Object*)n.res());
                continue;
                }
            if (op.equals(String.withCString("Store")))
                {
                if (n.ops().count() < (u32)2)
                    return (String*)0;
                if (!self.vecIsElemAddr((IROperand*)n.ops().get((u32)0), iv, defOf))
                    return (String*)0;
                if (!vecOperandOK((IROperand*)n.ops().get((u32)1), elems, B, (IRBlock*)defBlk.get((Hashable*)iv), defOf, defBlk))
                    return (String*)0;
                sawStore = true;
                continue;
                }
            // Scalar plumbing, kept verbatim — constants and the widen/narrow
            // of the step or of an invariant operand.
            if (op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                continue;
            if (vecElementwise(op))
                {
                if (n.res() == (IRValue*)0 || !self.vecLaneOK(n.res().ty()))
                    return (String*)0;
                if (n.ops().count() < (u32)2)
                    return (String*)0;
                if (!vecOperandOK((IROperand*)n.ops().get((u32)0), elems, B, (IRBlock*)defBlk.get((Hashable*)iv), defOf, defBlk))
                    return (String*)0;
                if (!vecOperandOK((IROperand*)n.ops().get((u32)1), elems, B, (IRBlock*)defBlk.get((Hashable*)iv), defOf, defBlk))
                    return (String*)0;
                elems.add((Object*)n.res());
                continue;
                }
            return (String*)0;
            }
        if (!sawLoad || !sawStore)
            return (String*)0;
        return laneTy;
        }

    // Usable in the elementwise computation: an already-elementwise value (one
    // vector lane each), or a loop-INVARIANT scalar — a constant, or something
    // defined outside the loop — which is the same in every lane and so safe to
    // broadcast.
    // A lane operand: a lane value, a constant, or loop-invariant — defined
    // outside both the body B and the header H, as the reference's
    // elemOperandOK (a header phi, the counter above all, changes every trip;
    // splatting it gave every lane the first lane's i).
    final bool vecOperandOK(IROperand* o, Array* elems, IRBlock* B, IRBlock* H, Map* defOf, Map* defBlk)
        {
        if (o.kind() == (u8)OPK_IMMI)
            return true;
        if (o.kind() != (u8)OPK_USE)
            return false;
        if (hasValue(elems, o.val()))
            return true;
        i32 k = (i32)0;
        if (vecConst(o, defOf, &k))
            return true;
        Object* db = defBlk.get((Hashable*)o.val());
        return db != (Object*)0 && (IRBlock*)db != B && (IRBlock*)db != H;
        }

    final bool vecReduxOperandOK(IROperand* o, Array* elems, IRBlock* B, IRBlock* H, Map* defOf, Map* defBlk)
        {
        if (o.kind() == (u8)OPK_USE)
            {
            Object* cd = defOf.get((Hashable*)o.val());
            if (cd != 0 && ((IRInsn*)cd).op().equals(String.withCString("Const")))
                return true;
            }
        return vecOperandOK(o, elems, B, H, defOf, defBlk);
        }

    // A compile-time constant: a literal, a Const, an extension of one, or
    // integer arithmetic of constants (`32 - c`, which the front end leaves
    // to the optimiser: ROTL's shift amount). Folded only where every value
    // involved is in [0, 2^31), so that both compilers' widths agree.
    final bool vecConst(IROperand* op, Map* defOf, i32* out)
        {
        i64 v = (i64)0;
        if (!self.vecFoldConst(op, defOf, (u32)0, &v))
            return false;
        out[0] = (i32)v;
        return true;
        }

    // EXTRACTED for the arm64 frame budget, like vecReduxEpilogue and
    // vecWidenEpiSetup before it: vecWideningAt sits AT the 16 KB ceiling, so
    // its body validation lives in its own frame. Pure checks -- the body must
    // be EXACTLY address / narrow load / widen / the two adds / constants
    // (anything else and the rewrite would drop work), the accumulator must not
    // be read elsewhere, and the induction variable must not escape the loop.
    final bool vecWideningBodyOK(IRFunc* fn, IRBlock* H, IRBlock* B, IRValue* iv,
                           IRValue* acc, IRInsn* accNext, IRInsn* ivNext,
                           IRInsn* zx, IRInsn* load)
        {
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* nn = (IRInsn*)B.insns().get(i);
            if (nn == accNext || nn == ivNext || nn == zx || nn == load)
                continue;
            String* op = nn.op();
            if (op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("ElementAddr")) || op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                continue;
            return false;
            }
        if (vecAccReadElsewhere(H, accNext, acc))
            return false;
        if (vecAccReadElsewhere(B, accNext, acc))
            return false;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (insnUsesValue((IRInsn*)bb.insns().get(i), iv))
                    return false;
            }
        return true;
        }

    final VecCand* vecWideningAt(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk, Map* uses)
        {
        if (vecIsRemainder(H))
            return (VecCand*)0;
        _vrAllowRT = true; // widening-sum / dot accept one too (see vecReduxShape)
        if (!vecReduxShape(H, defOf, defBlk))
            return (VecCand*)0;
        IRInsn* ivPhi = _vrIvPhi;
        IRInsn* accPhi = _vrAccPhi;
        IRBlock* B = _vrB;
        IRBlock* E = _vrE;
        IRValue* iv = _vrIv;
        i64 n = _vrN;
        IRValue* acc = accPhi.res();
        // The accumulator is unsigned 32-bit — that is what makes the widening
        // regrouping sound.
        if (!acc.ty().equals(String.withCString("U32")))
            return (VecCand*)0;

        IROperand* accBack = self.vecBackOp(accPhi, B);
        if (accBack == (IROperand*)0 || accBack.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* ao = defOf.get((Hashable*)accBack.val());
        Object* ab = defBlk.get((Hashable*)accBack.val());
        if (ao == (Object*)0 || ab == (Object*)0 || (IRBlock*)ab != B)
            return (VecCand*)0;
        IRInsn* accNext = (IRInsn*)ao;
        if (!accNext.op().equals(String.withCString("Add")) || self.countOf(uses, accBack.val()) != (u32)1 || accNext.ops().count() < (u32)2)
            return (VecCand*)0;
        IROperand* x0 = (IROperand*)accNext.ops().get((u32)0);
        IROperand* x1 = (IROperand*)accNext.ops().get((u32)1);
        IROperand* elemOp = (IROperand*)0;
        if (x0.kind() == (u8)OPK_USE && x0.val() == acc)
            elemOp = x1;
        else if (x1.kind() == (u8)OPK_USE && x1.val() == acc)
            elemOp = x0;
        if (elemOp == (IROperand*)0 || elemOp.kind() != (u8)OPK_USE)
            return (VecCand*)0;

        // The element is ZExt(load) — an unsigned widening of a narrow,
        // iv-indexed load that feeds nothing else.
        Object* zo = defOf.get((Hashable*)elemOp.val());
        Object* zb = defBlk.get((Hashable*)elemOp.val());
        if (zo == (Object*)0 || zb == (Object*)0 || (IRBlock*)zb != B)
            return (VecCand*)0;
        IRInsn* zx = (IRInsn*)zo;
        if (!zx.op().equals(String.withCString("ZExt")) || zx.ops().count() < (u32)1)
            return (VecCand*)0;
        IROperand* zs = (IROperand*)zx.ops().get((u32)0);
        if (zs.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* lo = defOf.get((Hashable*)zs.val());
        Object* lb = defBlk.get((Hashable*)zs.val());
        if (lo == (Object*)0 || lb == (Object*)0 || (IRBlock*)lb != B)
            return (VecCand*)0;
        IRInsn* load = (IRInsn*)lo;
        if (!load.op().equals(String.withCString("Load")) || load.res() == (IRValue*)0 || load.ops().count() < (u32)1)
            return (VecCand*)0;
        String* lt = load.res().ty();
        if (lt == (String*)0 || (!lt.equals(String.withCString("U8")) && !lt.equals(String.withCString("U16"))))
            return (VecCand*)0;
        if (!self.vecIsElemAddr((IROperand*)load.ops().get((u32)0), iv, defOf))
            return (VecCand*)0;
        if (countOf(uses, elemOp.val()) != (u32)1 || self.countOf(uses, load.res()) != (u32)1)
            return (VecCand*)0;

        IRInsn* ivNext = vecFindStep(B, iv, accNext, defOf);
        if (ivNext == (IRInsn*)0)
            return (VecCand*)0;
        IROperand* ivBack = self.vecBackOp(ivPhi, B);
        if (ivBack == (IROperand*)0 || ivBack.kind() != (u8)OPK_USE || ivBack.val() != ivNext.res())
            return (VecCand*)0;

        if (!vecWideningBodyOK(fn, H, B, iv, acc, accNext, ivNext, zx, load))
            return (VecCand*)0;

        u32 lw = self.irWidth(lt);
        if (lw == (u32)0)
            return (VecCand*)0;
        u32 wvb = self.vectorBytes(); // 16, or 32/64 on an x86-64 clone (bug 644)
        u32 vw = wvb / lw; // 16 per iteration for u8, 8 for u16
        // The trailing test is the non-zero-start refusal (see
        // vecIvStartsAtZero); folded into this condition rather than written as
        // its own statement, because a separate branch costs frame slots and
        // vecWideningAt sits 80 bytes from the arm64 budget.
        // The trip no longer has to be a whole number of vectors -- a CLONE
        // finishes the tail -- but fewer than ONE full vector still has nothing
        // to gain. That test is just `n < vw`: writing n = q*vw + r, the last
        // whole boundary n - r is q*vw, which is >= vw exactly when q >= 1. So
        // no subtraction and no second modulo, which matters because this
        // function sits ~80 bytes from the arm64 frame ceiling. The bound is
        // carried on the candidate for vecSetEpi to use.
        if (vw < (u32)2 || _vrIvStart < (i64)0)
            return (VecCand*)0;
        if (!_vrRuntime && _vrIvStart >= n)
            return (VecCand*)0;
        // Fewer than one whole vector: stay scalar. The test is on the trip
        // LENGTH `n - ivStart`, not the bound — gating on `n` accepted the
        // epilogue CLONE (iv enters at M, so its length is under a vector by
        // construction) and re-vectorised it into an EMPTY vector loop plus a
        // fresh clone, again every pipeline iteration. That runaway was the
        // vectorize_widen_tail opt-diff divergence: the reference refuses on
        // length and const-unrolls the tail instead.
        if (!_vrRuntime && n - _vrIvStart < (i32)vw)
            return (VecCand*)0;
        // A runtime bound needs a strict `<` and must be loop-INVARIANT.
        if (_vrRuntime && !self.vecMapRTOK(_vrGuard, defBlk, H, B))
            return (VecCand*)0;

        VecCand* c = new VecCand();
        c.setLoop(H, B, E);
        c.setIv(ivPhi, ivNext, _vrGuard, iv);
        c.setLane(String.withCString("U32"), vw);
        c.setVecBytes(wvb);
        c.setReduction(accPhi, accNext, acc, elemOp.val(),
                       self.vecEntryOpOf(accPhi, B), self.vecEntryBlkOf(accPhi, B));
        c.setWidening(lt, load.res(), (IRValue*)0, false);
        c.setRuntime(_vrRuntime, _vrBoundOp);
        c.setIvStart(_vrIvStart);
        return c;
        }

    final VecCand* vecDotAt(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk, Map* uses)
        {
        if (vecIsRemainder(H))
            return (VecCand*)0;
        _vrAllowRT = true; // widening-sum / dot accept one too (see vecReduxShape)
        if (!vecReduxShape(H, defOf, defBlk))
            return (VecCand*)0;
        IRInsn* ivPhi = _vrIvPhi;
        IRInsn* accPhi = _vrAccPhi;
        IRBlock* B = _vrB;
        IRBlock* E = _vrE;
        IRValue* iv = _vrIv;
        i64 n = _vrN;
        IRValue* acc = accPhi.res();
        if (!self.vecRedux32(acc.ty()))
            return (VecCand*)0;

        IROperand* accBack = self.vecBackOp(accPhi, B);
        if (accBack == (IROperand*)0 || accBack.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* ao = defOf.get((Hashable*)accBack.val());
        Object* ab = defBlk.get((Hashable*)accBack.val());
        if (ao == (Object*)0 || ab == (Object*)0 || (IRBlock*)ab != B)
            return (VecCand*)0;
        IRInsn* accNext = (IRInsn*)ao;
        if (!accNext.op().equals(String.withCString("Add")) || self.countOf(uses, accBack.val()) != (u32)1 || accNext.ops().count() < (u32)2)
            return (VecCand*)0;
        IROperand* x0 = (IROperand*)accNext.ops().get((u32)0);
        IROperand* x1 = (IROperand*)accNext.ops().get((u32)1);
        IROperand* elemOp = (IROperand*)0;
        if (x0.kind() == (u8)OPK_USE && x0.val() == acc)
            elemOp = x1;
        else if (x1.kind() == (u8)OPK_USE && x1.val() == acc)
            elemOp = x0;
        if (elemOp == (IROperand*)0 || elemOp.kind() != (u8)OPK_USE)
            return (VecCand*)0;

        // elem = ZExt(prod), prod = Mul(loadA, loadB) in the narrow lane.
        Object* zo = defOf.get((Hashable*)elemOp.val());
        Object* zb = defBlk.get((Hashable*)elemOp.val());
        if (zo == (Object*)0 || zb == (Object*)0 || (IRBlock*)zb != B)
            return (VecCand*)0;
        IRInsn* zx = (IRInsn*)zo;
        if (!zx.op().equals(String.withCString("ZExt")) || zx.ops().count() < (u32)1)
            return (VecCand*)0;
        if (countOf(uses, elemOp.val()) != (u32)1)
            return (VecCand*)0;
        IROperand* zs = (IROperand*)zx.ops().get((u32)0);
        if (zs.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* mo = defOf.get((Hashable*)zs.val());
        Object* mb = defBlk.get((Hashable*)zs.val());
        if (mo == (Object*)0 || mb == (Object*)0 || (IRBlock*)mb != B)
            return (VecCand*)0;
        IRInsn* mul = (IRInsn*)mo;
        if (!mul.op().equals(String.withCString("Mul")) || self.countOf(uses, zs.val()) != (u32)1 || mul.ops().count() < (u32)2)
            return (VecCand*)0;
        IROperand* m0 = (IROperand*)mul.ops().get((u32)0);
        IROperand* m1 = (IROperand*)mul.ops().get((u32)1);
        if (m0.kind() != (u8)OPK_USE || m1.kind() != (u8)OPK_USE)
            return (VecCand*)0;

        IRInsn* loadA = self.vecDotLoad(m0.val(), iv, B, defOf, defBlk, uses);
        IRInsn* loadB = self.vecDotLoad(m1.val(), iv, B, defOf, defBlk, uses);
        if (loadA == (IRInsn*)0 || loadB == (IRInsn*)0 || loadA == loadB)
            return (VecCand*)0;
        String* lt = loadA.res().ty();
        if (!lt.equals(loadB.res().ty()))
            return (VecCand*)0;

        IRInsn* ivNext = vecFindStep(B, iv, accNext, defOf);
        if (ivNext == (IRInsn*)0)
            return (VecCand*)0;
        IROperand* ivBack = self.vecBackOp(ivPhi, B);
        if (ivBack == (IROperand*)0 || ivBack.kind() != (u8)OPK_USE || ivBack.val() != ivNext.res())
            return (VecCand*)0;

        Array* known = new Array();
        known.add((Object*)accNext);
        known.add((Object*)ivNext);
        known.add((Object*)zx);
        known.add((Object*)mul);
        known.add((Object*)loadA);
        known.add((Object*)loadB);
        if (!vecDotBodyClean(fn, H, B, known, acc, accNext, iv))
            return (VecCand*)0;

        u32 lw = self.irWidth(lt);
        if (lw == (u32)0)
            return (VecCand*)0;
        u32 wvb = self.vectorBytes(); // 16, or 32/64 on an x86-64 clone (bug 644)
        u32 vw = wvb / lw;
        // The trailing test is the non-zero-start refusal (see
        // vecIvStartsAtZero); folded into this condition rather than written as
        // its own statement, because a separate branch costs frame slots and
        // vecWideningAt sits 80 bytes from the arm64 budget.
        // See vecWideningAt: `n < vw` is the fewer-than-one-vector refusal.
        if (vw < (u32)2 || _vrIvStart < (i64)0)
            return (VecCand*)0;
        if (!_vrRuntime && _vrIvStart >= n)
            return (VecCand*)0;
        // Fewer than one whole vector: stay scalar. On the trip LENGTH, not
        // the bound — see vecWideningAt for why gating on `n` re-vectorised
        // the epilogue clone into an empty vector loop, forever.
        if (!_vrRuntime && n - _vrIvStart < (i32)vw)
            return (VecCand*)0;
        // A runtime bound needs a strict `<` and must be loop-INVARIANT.
        if (_vrRuntime && !self.vecMapRTOK(_vrGuard, defBlk, H, B))
            return (VecCand*)0;
        IRBlock* PH = self.vecHeaderPred(fn, H, B);
        if (PH == (IRBlock*)0)
            return (VecCand*)0;

        VecCand* c = new VecCand();
        c.setLoop(H, B, E);
        c.setIv(ivPhi, ivNext, _vrGuard, iv);
        c.setLane(String.withCString("U32"), vw);
        c.setVecBytes(wvb);
        c.setReduction(accPhi, accNext, acc, elemOp.val(),
                       self.vecEntryOpOf(accPhi, B), PH);
        c.setWidening(lt, loadA.res(), loadB.res(), true);
        c.setRuntime(_vrRuntime, _vrBoundOp);
        c.setIvStart(_vrIvStart);
        return c;
        }

    // The body is exactly the recognised shape — two addresses, two loads, the
    // multiply, the widen, the two adds and constants — the accumulator is read
    // only by its own add, and the induction variable does not escape.
    final bool vecDotBodyClean(IRFunc* fn, IRBlock* H, IRBlock* B, Array* known,
                         IRValue* acc, IRInsn* accNext, IRValue* iv)
        {
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* nn = (IRInsn*)B.insns().get(i);
            if (hasInsn(known, nn))
                continue;
            String* op = nn.op();
            if (op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("ElementAddr")) || op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                continue;
            return false;
            }
        if (vecAccReadElsewhere(H, accNext, acc))
            return false;
        if (vecAccReadElsewhere(B, accNext, acc))
            return false;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (insnUsesValue((IRInsn*)bb.insns().get(i), iv))
                    return false;
            }
        return true;
        }

    // `ivNext = Add(iv, 1)` in the body, skipping the accumulator's own add.
    final IRInsn* vecFindStep(IRBlock* B, IRValue* iv, IRInsn* accNext, Map* defOf)
        {
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == accNext)
                continue;
            if (!n.op().equals(String.withCString("Add")) || n.res() == (IRValue*)0)
                continue;
            if (n.ops().count() < (u32)2)
                continue;
            IROperand* a0 = (IROperand*)n.ops().get((u32)0);
            IROperand* a1 = (IROperand*)n.ops().get((u32)1);
            IROperand* so = (IROperand*)0;
            if (a0.kind() == (u8)OPK_USE && a0.val() == iv)
                so = a1;
            else if (a1.kind() == (u8)OPK_USE && a1.val() == iv)
                so = a0;
            i32 one = (i32)0;
            if (so != (IROperand*)0 && vecConst(so, defOf, &one) && one == (i32)1)
                return n;
            }
        return (IRInsn*)0;
        }

    final bool vecMaxMinShape(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk)
        {
        _mmIvPhi = (IRInsn*)0;
        _mmAccPhi = (IRInsn*)0;
        _mmGuard = (IRInsn*)0;
        _mmJoinPhi = (IRInsn*)0;
        _mmIv = (IRValue*)0;
        _mmB = (IRBlock*)0;
        _mmE = (IRBlock*)0;
        _mmTH = (IRBlock*)0;
        _mmL = (IRBlock*)0;
        _mmPH = (IRBlock*)0;
        _mmN = (i32)0;

        if (H.phis().count() != (u32)2)
            return false;
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            if (((IRInsn*)H.insns().get(i)).memRes() != (IRValue*)0)
                return false;

        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE)
            return false;
        Object* go = defOf.get((Hashable*)c0.val());
        Object* gb = defBlk.get((Hashable*)c0.val());
        if (go == (Object*)0 || gb == (Object*)0 || (IRBlock*)gb != H)
            return false;
        IRInsn* guard = (IRInsn*)go;
        if (!guard.op().equals(String.withCString("ICmp")) || guard.ops().count() < (u32)2)
            return false;
        IROperand* gl = (IROperand*)guard.ops().get((u32)0);
        if (gl.kind() != (u8)OPK_USE)
            return false;
        IRValue* iv = gl.val();

        IRInsn* ivPhi = (IRInsn*)0;
        IRInsn* accPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0 || p.ops().count() != (u32)4)
                return false;
            if (p.res() == iv)
                ivPhi = p;
            else
                accPhi = p;
            }
        if (ivPhi == (IRInsn*)0 || accPhi == (IRInsn*)0)
            return false;
        i32 n = (i32)0;
        if (!vecConst((IROperand*)guard.ops().get((u32)1), defOf, &n) || n <= (i32)0)
            return false;

        // Both the preheader and the latch branch to the header, so they are
        // told apart by BLOCK ORDER: the back-edge source follows the header,
        // the preheader precedes it. Both phis must agree on the same latch.
        u32 idxH = self.blockIndex(fn, H);
        IRBlock* L = self.vecIncoming(fn, accPhi, idxH, true);
        IRBlock* PH = self.vecIncoming(fn, accPhi, idxH, false);
        if (L == (IRBlock*)0 || PH == (IRBlock*)0 || L == H || L == PH)
            return false;
        if (vecIncoming(fn, ivPhi, idxH, true) != L)
            return false;
        if (L.term() == (IRInsn*)0 || !L.term().op().equals(String.withCString("Branch")) || L.term().ops().count() < (u32)1 || ((IROperand*)L.term().ops().get((u32)0)).blk() != H)
            return false;

        // The join holds the accumulator's merge phi, the iv step and the branch.
        if (L.phis().count() != (u32)1)
            return false;
        IRInsn* joinPhi = (IRInsn*)L.phis().get((u32)0);
        if (joinPhi.res() == (IRValue*)0 || joinPhi.ops().count() != (u32)4)
            return false;
        IROperand* accBack = self.vecBackOp(accPhi, L);
        if (accBack == (IROperand*)0 || accBack.kind() != (u8)OPK_USE || accBack.val() != joinPhi.res())
            return false;

        // The diamond head is the guard target that feeds the join; the other
        // target exits.
        IRBlock* t0 = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* t1 = ((IROperand*)term.ops().get((u32)2)).blk();
        IRBlock* jb0 = ((IROperand*)joinPhi.ops().get((u32)0)).blk();
        IRBlock* jb1 = ((IROperand*)joinPhi.ops().get((u32)2)).blk();
        IRBlock* B = (IRBlock*)0;
        IRBlock* E = (IRBlock*)0;
        if (t0 == jb0 || t0 == jb1)
            {
            B = t0;
            E = t1;
            }
        else if (t1 == jb0 || t1 == jb1)
            {
            B = t1;
            E = t0;
            }
        else
            return false;
        IRBlock* TH = (jb0 == B) ? jb1 : jb0;
        if (B == (IRBlock*)0 || E == (IRBlock*)0 || TH == (IRBlock*)0 || B == TH)
            return false;
        if (B.phis().count() != (u32)0 || E.phis().count() != (u32)0)
            return false;

        _mmIvPhi = ivPhi;
        _mmAccPhi = accPhi;
        _mmGuard = guard;
        _mmJoinPhi = joinPhi;
        _mmIv = iv;
        _mmB = B;
        _mmE = E;
        _mmTH = TH;
        _mmL = L;
        _mmPH = PH;
        _mmN = n;
        return true;
        }

    final bool vecCountAcc(IRInsn* accPhi, IRValue* acc, IRBlock* B, IRBlock* L,
                     Map* defOf, Map* defBlk, Map* uses)
        {
        IROperand* accBack = ((IROperand*)accPhi.ops().get((u32)0)).blk() == L
                                 ? (IROperand*)accPhi.ops().get((u32)1)
                                 : (IROperand*)accPhi.ops().get((u32)3);
        if (accBack.kind() != (u8)OPK_USE)
            return false;
        Object* an = defOf.get((Hashable*)accBack.val());
        Object* ab = defBlk.get((Hashable*)accBack.val());
        if (an == (Object*)0 || ab == (Object*)0 || (IRBlock*)ab != B)
            return false;
        IRInsn* accNext = (IRInsn*)an;
        if (!accNext.op().equals(String.withCString("Select")) || accNext.ops().count() < (u32)3)
            return false;
        if (countOf(uses, accBack.val()) != (u32)1)
            return false;

        IROperand* condOp = (IROperand*)accNext.ops().get((u32)0);
        IROperand* tOp = (IROperand*)accNext.ops().get((u32)1);
        IROperand* fOp = (IROperand*)accNext.ops().get((u32)2);
        if (condOp.kind() != (u8)OPK_USE || tOp.kind() != (u8)OPK_USE || fOp.kind() != (u8)OPK_USE)
            return false;
        if (fOp.val() != acc)
            return false; // the unselected arm keeps acc

        Object* io = defOf.get((Hashable*)tOp.val());
        Object* ib = defBlk.get((Hashable*)tOp.val());
        if (io == (Object*)0 || ib == (Object*)0 || (IRBlock*)ib != B)
            return false;
        IRInsn* incr = (IRInsn*)io;
        if (!incr.op().equals(String.withCString("Add")) || incr.ops().count() < (u32)2)
            return false;
        IROperand* x0 = (IROperand*)incr.ops().get((u32)0);
        IROperand* x1 = (IROperand*)incr.ops().get((u32)1);
        IROperand* d = (IROperand*)0;
        if (x0.kind() == (u8)OPK_USE && x0.val() == acc)
            d = x1;
        else if (x1.kind() == (u8)OPK_USE && x1.val() == acc)
            d = x0;
        if (d == (IROperand*)0)
            return false;
        i32 dk = (i32)0;
        if (!vecConst(d, defOf, &dk))
            return false; // invariant increment

        Object* co = defOf.get((Hashable*)condOp.val());
        Object* cb = defBlk.get((Hashable*)condOp.val());
        if (co == (Object*)0 || cb == (Object*)0 || (IRBlock*)cb != B)
            return false;
        IRInsn* cmp = (IRInsn*)co;
        if (!cmp.op().equals(String.withCString("ICmp")) || cmp.ops().count() < (u32)2)
            return false;

        _vcAccNext = accNext;
        _vcIncr = incr;
        _vcCmp = cmp;
        _vcDelta = d;
        return true;
        }

    // Is this operand usable as an elementwise input: a literal, a value already
    // classified elementwise, a constant, or something defined OUTSIDE the loop
    // (hence invariant)? Anything else varies per lane in a way the rewrite
    // cannot reproduce.
    final bool vecCountOperandOK(IROperand* o, Array* elemIds, Map* defOf, Map* defBlk,
                           IRBlock* H, IRBlock* B, IRBlock* L)
        {
        if (o.kind() == (u8)OPK_IMMI)
            return true;
        if (o.kind() != (u8)OPK_USE)
            return false;
        if (hasValue(elemIds, o.val()))
            return true;
        i32 k = (i32)0;
        if (vecConst(o, defOf, &k))
            return true;
        Object* db = defBlk.get((Hashable*)o.val());
        if (db == (Object*)0)
            return false;
        return (IRBlock*)db != B && (IRBlock*)db != L && (IRBlock*)db != H;
        }

    // The body must be exactly the elementwise computation feeding the compare,
    // plus the count plumbing (compare, increment, Select, iv step) which is
    // skipped. Sets _vcLaneTy and _vcElem.
    final bool vecCountBody(IRBlock* B, IRBlock* H, IRBlock* L, IRValue* iv, IRInsn* ivNext,
                      Array* elemIds, Map* defOf, Map* defBlk)
        {
        _vcLaneTy = (String*)0;
        _vcElem = (IRValue*)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == _vcCmp || n == _vcIncr || n == _vcAccNext || n == ivNext)
                continue;
            String* op = n.op();
            if (op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                continue;
            if (op.equals(String.withCString("ElementAddr")))
                {
                if (n.ops().count() < (u32)2)
                    return false;
                IROperand* ix = (IROperand*)n.ops().get((u32)1);
                if (ix.kind() != (u8)OPK_USE || ix.val() != iv)
                    return false;
                continue;
                }
            if (op.equals(String.withCString("Load")))
                {
                if (n.ops().count() < (u32)1 || n.res() == (IRValue*)0)
                    return false;
                if (!self.vecIsElemAddr((IROperand*)n.ops().get((u32)0), iv, defOf))
                    return false;
                String* lt = n.res().ty();
                if (lt == (String*)0)
                    return false;
                // A NARROW element counts too: the compare and mask run at the
                // load's width and climb to the accumulator's with VAddLP. A
                // narrow lane only ever holds ONE iteration's mask before being
                // widened — the accumulation happens at 32 bits — so there is no
                // overflow beyond the delta having to fit the lane.
                if (!lt.equals(String.withCString("I32")) && !lt.equals(String.withCString("U32"))
                 && !lt.equals(String.withCString("I8"))  && !lt.equals(String.withCString("U8"))
                 && !lt.equals(String.withCString("I16")) && !lt.equals(String.withCString("U16")))
                    return false;
                if (_vcLaneTy != (String*)0 && !_vcLaneTy.equals(lt))
                    return false;
                _vcLaneTy = lt;
                _vcElem = n.res();
                if (!self.hasValue(elemIds, n.res()))
                    elemIds.add((Object*)n.res());
                continue;
                }
            if (vecElementwise(op))
                {
                if (n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
                    return false;
                if (!vecCountOperandOK((IROperand*)n.ops().get((u32)0), elemIds, defOf, defBlk, H, B, L))
                    return false;
                if (!vecCountOperandOK((IROperand*)n.ops().get((u32)1), elemIds, defOf, defBlk, H, B, L))
                    return false;
                if (!self.hasValue(elemIds, n.res()))
                    elemIds.add((Object*)n.res());
                continue;
                }
            return false;
            }
        return _vcLaneTy != (String*)0 && _vcElem != (IRValue*)0;
        }

    // The counter must be read ONLY by the Select and its increment, and the
    // induction variable must not escape the loop: either would still be live
    // after the rewrite replaced them.
    final bool vecCountClean(IRFunc* fn, IRBlock* H, IRBlock* B, IRBlock* L,
                       IRValue* acc, IRValue* iv)
        {
        if (vecCountAccRead(H, acc))
            return false;
        if (vecCountAccRead(B, acc))
            return false;
        if (vecCountAccRead(L, acc))
            return false;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B || bb == L)
                continue;
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                if (insnUsesValue((IRInsn*)bb.insns().get(i), iv))
                    return false;
            }
        return true;
        }

    // ivNext = Add(iv, 1) in the latch, found BEFORE the body is classified so
    // the classifier can skip it: when the body is merged it shares a block with
    // the count plumbing.
    final IRInsn* vecCountStep(IRBlock* L, IRValue* iv, Map* defOf)
        {
        for (u32 i = (u32)0; i < L.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)L.insns().get(i);
            if (!n.op().equals(String.withCString("Add")) || n.res() == (IRValue*)0)
                continue;
            if (n.ops().count() < (u32)2)
                continue;
            IROperand* a0 = (IROperand*)n.ops().get((u32)0);
            IROperand* a1 = (IROperand*)n.ops().get((u32)1);
            IROperand* so = (IROperand*)0;
            if (a0.kind() == (u8)OPK_USE && a0.val() == iv)
                so = a1;
            else if (a1.kind() == (u8)OPK_USE && a1.val() == iv)
                so = a0;
            if (so == (IROperand*)0)
                continue;
            i32 one = (i32)0;
            if (vecConst(so, defOf, &one) && one == (i32)1)
                return n;
            }
        return (IRInsn*)0;
        }

    // The compare must be elementwise-vs-invariant: exactly one side elementwise
    // and the other loop-invariant. Both sides elementwise would vary per lane on
    // the right too; neither would make the compare loop-invariant and the count
    // a multiple of the trip.
    //
    // The original also whitelists the ICmp predicate, but that list is every
    // predicate ICmp has (EQ NE ULT UGT ULE UGE SLT SGT SLE SGE), so testing it
    // would refuse nothing and cost frame this function does not have.
    final bool vecCountCmpOK(Array* elemIds, Map* defOf, Map* defBlk,
                       IRBlock* H, IRBlock* B, IRBlock* L)
        {
        IROperand* o0 = (IROperand*)_vcCmp.ops().get((u32)0);
        IROperand* o1 = (IROperand*)_vcCmp.ops().get((u32)1);
        bool e0 = o0.kind() == (u8)OPK_USE && self.hasValue(elemIds, o0.val());
        bool e1 = o1.kind() == (u8)OPK_USE && self.hasValue(elemIds, o1.val());
        if (e0 == e1)
            return false;
        IROperand* k = e0 ? o1 : o0;
        if (!vecCountOperandOK(k, elemIds, defOf, defBlk, H, B, L))
            return false;
        if (k.kind() == (u8)OPK_USE && self.hasValue(elemIds, k.val()))
            return false;
        return true;
        }

    // Splat a loop-INVARIANT operand in the preheader, so it is computed once on
    // loop entry rather than per iteration. A compile-time constant is
    // rematerialised there; a value defined before the loop is splatted directly.
    final IROperand* vecCountSplatPH(IRBlock* PH, IROperand* op, String* laneTy,
                               String* vecTy, Map* defOf)
        {
        IROperand* scalar = op;
        i32 k = (i32)0;
        if (vecConst(op, defOf, &k))
            {
            IRValue* cv = new IRValue(laneTy);
            IRInsn* ci = IRInsn.with(String.withCString("Const"));
            ci.setRes(cv);
            ci.add(IROperand.immI(k, laneTy));
            PH.insns().add((Object*)ci);
            scalar = IROperand.useVal(cv);
            }
        IRValue* sv = new IRValue(vecTy);
        IRInsn* si = IRInsn.with(String.withCString("VSplat"));
        si.setRes(sv);
        si.add(scalar);
        PH.insns().add((Object*)si);
        return IROperand.useVal(sv);
        }

    // An operand of the COMPARE: the elementwise side is already a vector, the
    // invariant side is splatted in the preheader.
    final IROperand* vecCountCmpOperand(IROperand* op, IRBlock* PH, String* laneTy,
                                  String* vecTy, Map* defOf)
        {
        if (op.kind() == (u8)OPK_USE)
            {
            Object* vv = _vecMap.get((Hashable*)op.val());
            if (vv != (Object*)0)
                return IROperand.useVal((IRValue*)vv);
            }
        return vecCountSplatPH(PH, op, laneTy, vecTy, defOf);
        }

    final VecCand* vecMaxMinAt(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk)
        {
        if (vecIsRemainder(H))
            return (VecCand*)0;
        if (!vecMaxMinShape(fn, H, defOf, defBlk))
            return (VecCand*)0;
        IRValue* iv = _mmIv;
        IRBlock* B = _mmB;
        IRBlock* TH = _mmTH;
        IRBlock* L = _mmL;
        IRValue* acc = _mmAccPhi.res();

        // The head: address, load, compare, conditional branch — nothing else.
        IRInsn* bterm = B.term();
        if (bterm == (IRInsn*)0 || !bterm.op().equals(String.withCString("CondBranch")) || bterm.ops().count() < (u32)3)
            return (VecCand*)0;
        IROperand* bc = (IROperand*)bterm.ops().get((u32)0);
        if (bc.kind() != (u8)OPK_USE)
            return (VecCand*)0;
        Object* co = defOf.get((Hashable*)bc.val());
        Object* cb = defBlk.get((Hashable*)bc.val());
        if (co == (Object*)0 || cb == (Object*)0 || (IRBlock*)cb != B)
            return (VecCand*)0;
        IRInsn* cmp = (IRInsn*)co;
        if (!cmp.op().equals(String.withCString("ICmp")))
            return (VecCand*)0;

        IRValue* elem = self.vecMaxMinHead(B, iv, defOf);
        if (elem == (IRValue*)0)
            return (VecCand*)0;
        String* laneTy = elem.ty();
        if (!self.vecMaxMinArms(B, TH, L, iv, acc, elem, defOf, defBlk))
            return (VecCand*)0;

        // ivNext = Add(iv, 1) in the join, and it is the iv phi's back edge.
        IRInsn* ivNext = (IRInsn*)0;
        for (u32 i = (u32)0; i < L.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)L.insns().get(i);
            if (!n.op().equals(String.withCString("Add")) || n.res() == (IRValue*)0)
                continue;
            if (n.ops().count() < (u32)2)
                continue;
            IROperand* x0 = (IROperand*)n.ops().get((u32)0);
            IROperand* x1 = (IROperand*)n.ops().get((u32)1);
            IROperand* so = (IROperand*)0;
            if (x0.kind() == (u8)OPK_USE && x0.val() == iv)
                so = x1;
            else if (x1.kind() == (u8)OPK_USE && x1.val() == iv)
                so = x0;
            i32 one = (i32)0;
            if (so != (IROperand*)0 && vecConst(so, defOf, &one) && one == (i32)1)
                {
                ivNext = n;
                break;
                }
            }
        if (ivNext == (IRInsn*)0)
            return (VecCand*)0;
        IROperand* ivBack = self.vecBackOp(_mmIvPhi, L);
        if (ivBack == (IROperand*)0 || ivBack.kind() != (u8)OPK_USE || ivBack.val() != ivNext.res())
            return (VecCand*)0;

        // Max or min, and the signedness, from the compare. The true arm keeps
        // the element, so "element is larger" means max.
        IROperand* ca = (IROperand*)cmp.ops().get((u32)0);
        IROperand* cbb = (IROperand*)cmp.ops().get((u32)1);
        bool elemLeft = false;
        if (ca.kind() == (u8)OPK_USE && ca.val() == elem && cbb.kind() == (u8)OPK_USE && cbb.val() == acc)
            elemLeft = true;
        else if (ca.kind() == (u8)OPK_USE && ca.val() == acc && cbb.kind() == (u8)OPK_USE && cbb.val() == elem)
            elemLeft = false;
        else
            return (VecCand*)0;
        String* pr = cmp.pred();
        if (pr == (String*)0)
            return (VecCand*)0;
        bool gtFam = pr.equals(String.withCString("UGT")) || pr.equals(String.withCString("SGT")) || pr.equals(String.withCString("UGE")) || pr.equals(String.withCString("SGE"));
        bool ltFam = pr.equals(String.withCString("ULT")) || pr.equals(String.withCString("SLT")) || pr.equals(String.withCString("ULE")) || pr.equals(String.withCString("SLE"));
        if (!gtFam && !ltFam)
            return (VecCand*)0;
        bool signedCmp = pr.equals(String.withCString("SGT")) || pr.equals(String.withCString("SLT")) || pr.equals(String.withCString("SGE")) || pr.equals(String.withCString("SLE"));
        if (signedCmp != laneTy.equals(String.withCString("I32")))
            return (VecCand*)0;
        bool isMax = elemLeft ? gtFam : ltFam;

        IROperand* seedOp = self.vecEntryOpOf(_mmAccPhi, L);
        u32 lw = self.irWidth(laneTy);
        if (lw == (u32)0)
            return (VecCand*)0;
        u32 vb = self.vectorBytes();
        u32 vw = vb / lw;
        if (vw < (u32)2 || (_mmN % (i32)vw) != (i32)0)
            return (VecCand*)0;

        VecCand* c = new VecCand();
        c.setLoop(H, B, _mmE);
        c.setIv(_mmIvPhi, ivNext, _mmGuard, iv);
        c.setLane(laneTy, vw);
        c.setVecBytes(vb);
        c.setReduction(_mmAccPhi, (IRInsn*)0, acc, elem, seedOp, _mmPH);
        c.setMaxMin(isMax, TH, L);
        return c;
        }

    final void vecRepairMem(IRFunc* fn, VecCand* c, IRBlock* B, IRBlock* L)
        {
        Array* gone = new Array();
        self.vecCollectDefs(gone, c.mmThen());
        self.vecCollectDefs(gone, L);
        IRValue* liveMem = (IRValue*)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n.memRes() != (IRValue*)0)
                liveMem = n.memRes();
            }
        if (gone.count() == (u32)0 || liveMem == (IRValue*)0)
            return;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == L || bb == c.mmThen())
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                self.vecRewireGone((IRInsn*)bb.phis().get(k), gone, liveMem);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                self.vecRewireGone((IRInsn*)bb.insns().get(k), gone, liveMem);
            if (bb.term() != (IRInsn*)0)
                self.vecRewireGone(bb.term(), gone, liveMem);
            }
        }

    // The pool for a loop over vectors of type t: on x86 a 64-byte (AVX-512)
    // loop has zmm16-31 too, which the back end gives to classes whose every
    // value is 64 bytes: 30, not 14 (MD5's 64 rounds then interleave two lane
    // groups, as clang does). As the reference.
    final u32 vecPoolForTy(IRFunc* fn, String* t)
        {
        if (!_profile.bitSelect() && t != (String*)0 && t.hasSuffix(String.withCString(", 64)")))
            return (u32)30;
        return self.vecPoolFor(fn);
        }

    // In a big body, a lane vector built from a scalar, `VAdd(VSplat(x), t)`
    // with t from outside the body (the iota: `<i, i+1, i+2, i+3>`), is
    // rebuilt next to each later use instead of held: two cheap ops against a
    // register for the whole body (MD5's candidate word, read in four
    // rounds). As the reference's vecRematLanes.
    final void vecRematLanes(IRFunc* fn, IRBlock* B, Map* defBlk)
        {
        Map* defIn = new Map();
        Map* usesIn = new Map();
        self.countUses(usesIn, B.insns());
        Map* usesAll = self.useCounts(fn);
        Array* out = new Array();
        Map* lane = new Map();
        Map* seen = new Map();
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                    continue;
                IRInsn* va = (IRInsn*)lane.get((Hashable*)o.val());
                if (va == (IRInsn*)0)
                    continue;
                if (seen.get((Hashable*)o.val()) == (Object*)0)
                    {
                    seen.set((Hashable*)o.val(), (Object*)o.val());
                    continue;
                    }
                // A later use: a fresh splat and add, just before it.
                IROperand* v0 = (IROperand*)va.ops().get((u32)0);
                IROperand* v1 = (IROperand*)va.ops().get((u32)1);
                IRInsn* sp = (IRInsn*)defIn.get((Hashable*)v0.val());
                u32 ti = sp != (IRInsn*)0 ? (u32)1 : (u32)0;
                if (sp == (IRInsn*)0)
                    sp = (IRInsn*)defIn.get((Hashable*)v1.val());
                IRValue* s2 = new IRValue(sp.res().ty());
                IRInsn* sn = IRInsn.with(String.withCString("VSplat"));
                sn.copyDbg(n);
                sn.setRes(s2);
                for (u32 q = (u32)0; q < sp.ops().count(); q = q + (u32)1)
                    sn.add((IROperand*)sp.ops().get(q));
                out.add((Object*)sn);
                IRValue* a2 = new IRValue(va.res().ty());
                IRInsn* an = IRInsn.with(String.withCString("VAdd"));
                an.copyDbg(n);
                an.setRes(a2);
                if (ti == (u32)1)
                    {
                    an.add(IROperand.useVal(s2));
                    an.add(v1);
                    }
                else
                    {
                    an.add(v0);
                    an.add(IROperand.useVal(s2));
                    }
                out.add((Object*)an);
                n.ops().set(k, (Object*)IROperand.useVal(a2));
                }
            out.add((Object*)n);
            if (n.res() != (IRValue*)0)
                defIn.set((Hashable*)n.res(), (Object*)n);
            // Is this such a lane vector? VAdd of a single-use in-body VSplat
            // and an outside value, read only in B, more than once.
            if (n.op().equals(String.withCString("VAdd")) && n.res() != (IRValue*)0 && n.ops().count() == (u32)2
                && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_USE
                && ((IROperand*)n.ops().get((u32)1)).kind() == (u8)OPK_USE
                && self.countOf(usesIn, n.res()) > (u32)1 && self.countOf(usesIn, n.res()) == self.countOf(usesAll, n.res()))
                {
                for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
                    {
                    IRInsn* sp = (IRInsn*)defIn.get((Hashable*)((IROperand*)n.ops().get(k)).val());
                    IROperand* t = (IROperand*)n.ops().get((u32)1 - k);
                    if (sp != (IRInsn*)0 && sp.op().equals(String.withCString("VSplat"))
                        && self.countOf(usesAll, sp.res()) == (u32)1
                        && defIn.get((Hashable*)t.val()) == (Object*)0
                        && (IRBlock*)defBlk.get((Hashable*)t.val()) != B)
                        {
                        lane.set((Hashable*)n.res(), (Object*)n);
                        break;
                        }
                    }
                }
            }
        B.insns().removeAll();
        for (u32 i = (u32)0; i < out.count(); i = i + (u32)1)
            B.insns().add(out.get(i));
        }

    final void vecUnrollApply(IRFunc* fn, IRBlock* H, IRBlock* B, IRBlock* E, IRBlock* PH,
                        IRValue* iv, IRValue* vacc, String* vecTy,
                        IRInsn* ivNextInsn, IRInsn* vnextInsn, IRInsn* initInsn,
                        i32 vw, u32 U, bool bigBody)
        {
        String* ivTy = ivNextInsn.res().ty();

        // The iv-dependent chain, in order, EXCEPT the iv step (re-stepped to
        // U*vw separately). vnextInsn is in it, because it consumes a value that
        // depends on the iv.
        Array* dep = new Array();
        dep.add((Object*)iv);
        Array* ivDep = new Array();
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == ivNextInsn)
                continue;
            bool d = false;
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() == (u8)OPK_USE && self.hasValue(dep, o.val()))
                    {
                    d = true;
                    break;
                    }
                }
            if (!d)
                continue;
            ivDep.add((Object*)n);
            if (n.res() != (IRValue*)0)
                dep.add((Object*)n.res());
            }

        Array* appended = new Array();
        Array* newPhis = new Array();
        Array* accs = new Array();
        accs.add((Object*)vacc); // copy 0 is the original
        for (u32 k = (u32)1; k < U; k = k + (u32)1)
            self.vecUnrollCopy(k, vw, ivTy, vecTy, iv, vacc, B, PH, initInsn, vnextInsn,
                          ivDep, appended, newPhis, accs);

        self.vecUnrollSplice(fn, H, B, E, iv, vacc, vecTy, ivNextInsn, vnextInsn,
                        ivTy, vw, U, appended, newPhis, accs, bigBody ? ivDep : (Array*)0);
        }

    // The widening-sum rewrite, shared with the dot product: vector-load the
    // narrow array (16×u8 or 8×u16), fold the lanes up to u32 by repeated
    // pairwise widening, accumulate in a 4×u32 vector, reduce at the exit. The
    // accumulator update stays a plain VAdd, so the multi-accumulator unroller
    // then treats it like any other add reduction.
    // EXTRACTED purely for the arm64 frame budget, like vecReduxEpilogue:
    // vecWideningAt sits ~80 bytes from the 16 KB ceiling, and computing the
    // epilogue bound inline pushed it 240 bytes OVER. Every IR value gets its
    // own frame slot, so two lines of arithmetic cost far more stack than they
    // look like they should. Sets the candidate's epilogue fields; returns false
    // when the loop has fewer than one whole vector and must stay scalar.
    // Epilogue part 1 for the widening/dot applier, EXTRACTED for the arm64
    // frame budget exactly as vecReduxEpilogue was: inlined, the clone, its map
    // and the guard rewrite pushed vecApplyWidening to 17168 bytes against a
    // 16384 ceiling. Part 2 needs no code here -- the applier ends in
    // vecReduxExit, which lands the horizontal add in a VE landing pad and
    // seeds the clone whenever needEpi() is set.
    final void vecWidenEpiSetup(IRFunc* fn, VecCand* c, IRBlock* H, IRBlock* B, IRBlock* PH)
        {
        _vecH2 = (IRBlock*)0;
        _vecB2 = (IRBlock*)0;
        _vecCmap = (Map*)0;
        _vecPH = (IRBlock*)0;
        self.vecSetEpi(c);
        if (!c.needEpi())
            return;
        Map* cmap = new Map();
        Array* cl = self.vecCloneLoop(fn, H, B, cmap);
        _vecH2 = (IRBlock*)cl.get((u32)0);
        _vecRemainders.set((Hashable*)_vecH2, (Object*)_vecH2);
        _vecB2 = (IRBlock*)cl.get((u32)1);
        _vecCmap = cmap;
        _vecPH = PH;
        // The vector loop now stops at the last whole vector; the clone's own
        // (cloned) guard still tests the original bound.
        if (c.rtTrip())
            {
            _vecRtM = self.vecRuntimeLimit(c, PH);
            c.guard().ops().set((u32)1, (Object*)IROperand.useVal(_vecRtM));
            }
        else
            {
            _vecRtM = (IRValue*)0;
            c.guard().ops().set((u32)1, (Object*)IROperand.immI(c.epiM(), c.iv().ty()));
            }
        }

    final void vecApplyWidening(IRFunc* fn, VecCand* c)
        {
        IRBlock* B = c.b();
        IRBlock* H = c.h();
        IRBlock* PH = c.pre();

        // Epilogue part 1: clone the scalar loop BEFORE the body and the
        // header's phis are rewritten in place. Part 2 comes free — this
        // applier already ends in vecReduxExit, which lands the horizontal add
        // in a VE landing pad and seeds the clone whenever needEpi() is set.
        vecWidenEpiSetup(fn, c, H, B, PH);
        String* u32t = String.withCString("U32");
        String* accVecTy = self.vecTyOf(u32t, c.vecBytes());
        String* loadVecTy = self.vecTyOf(c.loadLaneTy(), c.vecBytes());

        // For a dot product the accumulated element is ZExt(Mul(a,b)); find that
        // scalar multiply so it and its widening can become a VMul of the two
        // vector loads.
        IRValue* mul = (IRValue*)0;
        if (c.isDot())
            {
            for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)B.insns().get(i);
                if (!n.op().equals(String.withCString("Mul")) || n.res() == (IRValue*)0 || n.ops().count() < (u32)2)
                    continue;
                IROperand* m0 = (IROperand*)n.ops().get((u32)0);
                IROperand* m1 = (IROperand*)n.ops().get((u32)1);
                if (m0.kind() != (u8)OPK_USE || m1.kind() != (u8)OPK_USE)
                    continue;
                if ((m0.val() == c.load() && m1.val() == c.load2()) || (m0.val() == c.load2() && m1.val() == c.load()))
                    {
                    mul = n.res();
                    break;
                    }
                }
            }
        IRValue* zxSrc = c.isDot() ? mul : c.load();

        IRValue* vacc = new IRValue(accVecTy);
        Array* nb = new Array();
        Array* vls = self.vecWideningLoads(c, B, mul, zxSrc, loadVecTy, nb);
        IRValue* vload = (IRValue*)vls.get((u32)0);
        IRValue* vload2 = (IRValue*)vls.get((u32)1);
        if (vload == (IRValue*)0)
            return;

        // The dot product multiplies in the NARROW lane first: VMul keeps the low
        // half, so it wraps exactly like the scalar u16*u16 it replaces.
        IRValue* cur = vload;
        if (c.isDot())
            {
            if (vload2 == (IRValue*)0)
                return;
            IRValue* vprod = new IRValue(loadVecTy);
            IRInsn* vm = IRInsn.with(String.withCString("VMul"));
            vm.setRes(vprod);
            vm.add(IROperand.useVal(vload));
            vm.add(IROperand.useVal(vload2));
            nb.add((Object*)vm);
            cur = vprod;
            }
        // Fold the lanes up to u32, one pairwise widening at a time.
        String* curLane = c.loadLaneTy();
        while (irWidth(curLane) < (u32)4)
            {
            String* nextLane = self.irWidth(curLane) == (u32)1
                                   ? String.withCString("U16")
                                   : u32t;
            String* wTy = self.vecTyOf(nextLane, c.vecBytes());
            IRValue* w = new IRValue(wTy);
            IRInsn* wi = IRInsn.with(String.withCString("VAddLP"));
            wi.setRes(w);
            wi.add(IROperand.useVal(cur));
            nb.add((Object*)wi);
            cur = w;
            curLane = nextLane;
            }
        IRValue* vnext = new IRValue(accVecTy);
        IRInsn* va = IRInsn.with(String.withCString("VAdd"));
        va.setRes(vnext);
        va.add(IROperand.useVal(vacc));
        va.add(IROperand.useVal(cur));
        nb.add((Object*)va);
        B.setInsns(nb);

        // The iv steps by the lane count — 16 for u8, 8 for u16.
        for (u32 k = (u32)0; k < c.ivNext().ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)c.ivNext().ops().get(k);
            if (o.kind() == (u8)OPK_IMMI || (o.kind() == (u8)OPK_USE && o.val() != c.iv()))
                c.ivNext().ops().set(k,
                                     (Object*)IROperand.immI((i32)c.vw(), c.ivNext().res().ty()));
            }

        self.vecZeroSeedPhi(c, H, B, PH, accVecTy, u32t, vacc, vnext);
        vecReduxExit(fn, c, vacc);
        _vecSplatPH = (IRBlock*)0;
        }

    // The min/max rewrite. The diamond collapses to a single straight-line
    // vector latch: keep the address computation, vector-load the element, fold
    // it in with VMax/VMin, step the iv by the vector width, branch back. The
    // then-arm and the join go away entirely.
    final void vecApplyMaxMin(IRFunc* fn, VecCand* c)
        {
        IRBlock* B = c.b();
        IRBlock* H = c.h();
        IRBlock* E = c.e();
        IRBlock* PH = c.pre();
        IRBlock* L = c.mmLatch();
        String* vecTy = new String();
        vecTy = self.vecTyOf(c.laneTy(), c.vecBytes());

        // Creation order matters: fresh values take ids in creation (seq)
        // order, and the original allocates vacc, vload, vnext, ivNext.
        IRValue* vacc = new IRValue(vecTy);
        IRValue* vload = new IRValue(vecTy);
        IRValue* vnext = new IRValue(vecTy);
        IRValue* ivNextV = new IRValue(c.ivNext().res().ty());
        if (!self.vecMaxMinLatch(c, B, H, vecTy, vacc, vload, vnext, ivNextV))
            return;

        // The vector accumulator seeds every lane with the scalar seed: min and
        // max are idempotent, so no end-combine is needed for the seed.
        IRValue* vacc0 = new IRValue(vecTy);
        IRInsn* sp = IRInsn.with(String.withCString("VSplat"));
        sp.setRes(vacc0);
        sp.add(c.seed());
        PH.insns().add((Object*)sp);
        IRInsn* vphi = IRInsn.with(String.withCString("Phi"));
        vphi.setRes(vacc);
        vphi.add(IROperand.block(PH));
        vphi.add(IROperand.useVal(vacc0));
        vphi.add(IROperand.block(B));
        vphi.add(IROperand.useVal(vnext));

        Array* newPhis = new Array();
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p == c.accPhi())
                {
                newPhis.add((Object*)vphi);
                continue;
                }
            // The iv phi's back edge moves from the old join to the new latch.
            for (u32 k = (u32)0; k + (u32)1 < p.ops().count(); k = k + (u32)2)
                {
                IROperand* bo = (IROperand*)p.ops().get(k);
                if (bo.kind() != (u8)OPK_BLOCK || bo.blk() != L)
                    continue;
                p.ops().set(k, (Object*)IROperand.block(B));
                p.ops().set(k + (u32)1, (Object*)IROperand.useVal(ivNextV));
                }
            newPhis.add((Object*)p);
            }
        H.setPhis(newPhis);

        // Repair the memory chain BEFORE the diamond goes. The scalar loop
        // threaded its token through the then-arm's reload, so post-loop code
        // reads a token defined in a block about to disappear; every value
        // defined in the arm or the join becomes the surviving VLoad's token.
        // Skipping this leaves a reference with no definition — which the
        // original's printer spells `%?36` and this one hides behind a stale
        // parse-time id, so neither says it out loud.
        vecRepairMem(fn, c, B, L);

        // The diamond arm and the join are now unreachable.
        Array* keep = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb != L && bb != c.mmThen())
                keep.add((Object*)bb);
            }
        fn.setBlocks(keep);

        // Horizontal reduce at the exit, and the live-out readers follow it.
        IRValue* red = new IRValue(c.laneTy());
        IRInsn* rd = IRInsn.with(c.isMax() ? String.withCString("VReduceMax")
                                           : String.withCString("VReduceMin"));
        rd.setRes(red);
        rd.add(IROperand.useVal(vacc));
        E.insns().insert((u32)0, (Object*)rd);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                self.vecReplaceUse((IRInsn*)bb.phis().get(k), c.acc(), red, rd);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                self.vecReplaceUse((IRInsn*)bb.insns().get(k), c.acc(), red, rd);
            if (bb.term() != (IRInsn*)0)
                self.vecReplaceUse(bb.term(), c.acc(), red, rd);
            }
        }

    final void vecReduxExit(IRFunc* fn, VecCand* c, IRValue* vacc)
        {
        Map* defOf = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                if (n.res() != (IRValue*)0)
                    defOf.set((Hashable*)n.res(), (Object*)n);
                }
            }
        IRValue* red = new IRValue(c.laneTy());
        IRInsn* rd = IRInsn.with(String.withCString("VReduceAdd"));
        rd.setRes(red);
        rd.add(IROperand.useVal(vacc));
        Array* head = new Array();
        head.add((Object*)rd);
        IRValue* outV = red;
        i32 initK = (i32)0;
        bool initIsZero = vecConst(c.seed(), defOf, &initK) && initK == (i32)0;
        if (!initIsZero)
            {
            IRValue* withInit = new IRValue(c.laneTy());
            // FADD for a float lane: the seed is an f32 (nbody's 0.0f) and an
            // integer Add with s-registers is not an encodable instruction.
            bool laneF = c.laneTy() != (String*)0 && c.laneTy().equals(String.withCString("F32"));
            IRInsn* ai = IRInsn.with(String.withCString(laneF ? "FAdd" : "Add"));
            ai.setRes(withInit);
            ai.add(IROperand.useVal(red));
            ai.add(c.seed());
            head.add((Object*)ai);
            outV = withInit;
            }
        IRValue* finalV = outV;
        if (c.needEpi())
            finalV = self.vecReduxEpilogue(fn, c, outV, head);
        else
            {
            for (u32 i = (u32)0; i < head.count(); i = i + (u32)1)
                c.e().insns().insert(i, head.get(i));
            }

        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            // The clone legitimately reads the original accumulator through its
            // own remapped values; rewriting inside it would point the remainder
            // at its own result.
            if (bb == c.h() || bb == c.b() || bb == _vecH2 || bb == _vecB2)
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                self.vecReplaceUse((IRInsn*)bb.phis().get(k), c.acc(), finalV, rd);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                self.vecReplaceUse((IRInsn*)bb.insns().get(k), c.acc(), finalV, rd);
            if (bb.term() != (IRInsn*)0)
                self.vecReplaceUse(bb.term(), c.acc(), finalV, rd);
            }
        }

    // The exit of an ORDERED float sum: the scalar accumulator already holds
    // the total, in order; only the remainder loop (if any) follows it, and
    // the readers after the loop read its result.
    final void vecOrderedExit(IRFunc* fn, VecCand* c)
        {
        IRValue* finalV = c.acc();
        if (c.needEpi())
            finalV = self.vecReduxEpilogue(fn, c, c.acc(), new Array());
        if (finalV == c.acc())
            return;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == c.h() || bb == c.b() || bb == _vecH2 || bb == _vecB2)
                continue;
            for (u32 k = (u32)0; k < bb.phis().count(); k = k + (u32)1)
                self.vecReplaceUse((IRInsn*)bb.phis().get(k), c.acc(), finalV, (IRInsn*)0);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                self.vecReplaceUse((IRInsn*)bb.insns().get(k), c.acc(), finalV, (IRInsn*)0);
            if (bb.term() != (IRInsn*)0)
                self.vecReplaceUse(bb.term(), c.acc(), finalV, (IRInsn*)0);
            }
        }

    // Rewrite the reduction loop's body into vector form.
    final void vecReduxBody(VecCand* c, IRBlock* B, IRValue* vacc)
        {
        // Value ids used anywhere, so the body walk can drop a fully dead load
        // exactly as the recogniser skipped it (a guard's leftover flag load).
        Map* used = new Map();
        for (u32 b = (u32)0; b < _vecFn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*) _vecFn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.phis().get(i);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                        used.set((Hashable*)o.val(), (Object*)Number.with(self.countOf(used, o.val()) + (u32)1));
                    }
                }
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)bb.insns().get(i);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)n.ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                        used.set((Hashable*)o.val(), (Object*)Number.with(self.countOf(used, o.val()) + (u32)1));
                    }
                }
            if (bb.term() != 0)
                for (u32 k = (u32)0; k < bb.term().ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)bb.term().ops().get(k);
                    if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                        used.set((Hashable*)o.val(), (Object*)Number.with(self.countOf(used, o.val()) + (u32)1));
                    }
            }

        // IOTA. The per-lane value is derived from the induction variable, so
        // lane l of this iteration must hold i+l, not i. Splatting i would give
        // every lane the same value and compute a different answer.
        //
        //   preheader:  viota = VLoad(&__xtv_iota_<fn>_4)   <0,1,2,3>, once
        //   body:       viv   = VAdd(VSplat(i), viota)      <i,i+1,i+2,i+3>
        //
        // Mapping the iv to viv makes every rule below work unchanged: the
        // arithmetic on i vectorises through vecSplatOperand exactly as
        // arithmetic on a loaded element does.
        if (c.isIota() && c.pre() != (IRBlock*)0)
            {
            String* nm = self.vecIotaSymbol(c.laneTy(), c.vecBytes(), _vecFn);
            String* pty = new String();
            pty.appendFormat("Ptr(%s, unbanked)", c.laneTy().cString());
            IRValue* iotaPtr = new IRValue(pty);
            IRInsn* ao = IRInsn.with(String.withCString("AddrOf"));
            ao.setRes(iotaPtr);
            ao.add(IROperand.sym(nm));
            c.pre().insns().add((Object*)ao);
            IRValue* viota = new IRValue(_vecTy);
            IRInsn* vl = IRInsn.with(String.withCString("VLoad"));
            vl.setRes(viota);
            vl.add(IROperand.useVal(iotaPtr));
            c.pre().insns().add((Object*)vl);
            IRValue* vsp = new IRValue(_vecTy);
            IRInsn* sp = IRInsn.with(String.withCString("VSplat"));
            sp.setRes(vsp);
            sp.add(IROperand.useVal(c.iv()));
            _vecBody.add((Object*)sp);
            IRValue* viv = new IRValue(_vecTy);
            IRInsn* va = IRInsn.with(String.withCString("VAdd"));
            va.setRes(viv);
            va.add(IROperand.useVal(vsp));
            va.add(IROperand.useVal(viota));
            _vecBody.add((Object*)va);
            _vecMap.set((Hashable*)c.iv(), (Object*)viv);
            }
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n == c.ivNext())
                {
                IROperand* a0 = (IROperand*)n.ops().get((u32)0);
                IROperand* a1 = (IROperand*)n.ops().get((u32)1);
                bool ivLeft = a0.kind() == (u8)OPK_USE && a0.val() == c.iv();
                IRInsn* add = IRInsn.with(String.withCString("Add"));
                add.copyDbg(n);
                add.setRes(n.res());
                add.add(ivLeft ? a0 : a1);
                add.add(IROperand.immI((i32)c.vw(), n.res().ty()));
                _vecBody.add((Object*)add);
                continue;
                }
            // ordered: acc + e[0] + e[1] + ..., the lanes in order, scalar.
            if (n == c.accNext() && c.ordered())
                {
                IROperand* ve = vecSplatOperand(IROperand.useVal(c.elem()));
                IRValue* t = c.acc();
                for (u32 k = (u32)0; k < c.vw(); k = k + (u32)1)
                    {
                    IRValue* x = new IRValue(c.laneTy());
                    IRInsn* ex = IRInsn.with(String.withCString("VExtract"));
                    ex.copyDbg(n);
                    ex.setRes(x);
                    ex.add(ve);
                    ex.add(IROperand.immI((i64)k, String.withCString("U32")));
                    _vecBody.add((Object*)ex);
                    IRValue* sum = k + (u32)1 == c.vw() ? n.res() : new IRValue(c.laneTy());
                    IRInsn* fa = IRInsn.with(String.withCString("FAdd"));
                    fa.copyDbg(n);
                    fa.setRes(sum);
                    fa.add(IROperand.useVal(t));
                    fa.add(IROperand.useVal(x));
                    _vecBody.add((Object*)fa);
                    t = sum;
                    }
                continue;
                }
            // vacc += vec(elem)
            if (n == c.accNext())
                {
                IRValue* vnext = new IRValue(_vecTy);
                IROperand* velem = vecSplatOperand(IROperand.useVal(c.elem()));
                IRInsn* va = IRInsn.with(String.withCString("VAdd"));
                va.copyDbg(n);
                va.setRes(vnext);
                va.add(IROperand.useVal(vacc));
                va.add(velem);
                _vecBody.add((Object*)va);
                _vecMap.set((Hashable*)n.res(), (Object*)vnext);
                continue;
                }
            String* op = n.op();
            if (op.equals(String.withCString("AddrOf")) || op.equals(String.withCString("ElementAddr")) || op.equals(String.withCString("Const")) || op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt")) || op.equals(String.withCString("Trunc")))
                {
                _vecBody.add((Object*)n);
                continue;
                }
            // A value computed from constants alone stays the scalar it is;
            // its users read it as a constant.
            i32 kq = (i32)0;
            if (n.res() != (IRValue*)0 && vecConst(IROperand.useVal(n.res()), _vecSplatDefs, &kq))
                {
                _vecBody.add((Object*)n);
                continue;
                }
            if (op.equals(String.withCString("Load")))
                {
                // Mirror the recogniser: a fully DEAD load is dropped, so a
                // guard's leftover flag load does not become a bogus VLoad.
                if (n.res() != (IRValue*)0 && self.countOf(used, n.res()) == (u32)0
                    && (n.memRes() == (IRValue*)0 || self.countOf(used, n.memRes()) == (u32)0))
                    continue;
                IRValue* vr = new IRValue(_vecTy);
                IRInsn* vl = IRInsn.with(String.withCString("VLoad"));
                vl.copyDbg(n);
                vl.setRes(vr);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    vl.add((IROperand*)n.ops().get(k));
                vl.setMemRes(n.memRes());
                _vecBody.add((Object*)vl);
                _vecMap.set((Hashable*)n.res(), (Object*)vr);
                continue;
                }
            // A store of an elementwise value: the vectorised form writes the
            // whole vector at once. Mirrors the map applier; the recogniser has
            // already proved the address is iv-indexed and the value is
            // elementwise.
            if (op.equals(String.withCString("Store")))
                {
                IROperand* vval = vecSplatOperand((IROperand*)n.ops().get((u32)1));
                IRInsn* vs = IRInsn.with(String.withCString("VStore"));
                vs.copyDbg(n);
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    vs.add(k == (u32)1 ? vval : (IROperand*)n.ops().get(k));
                vs.setMemRes(n.memRes());
                _vecBody.add((Object*)vs);
                continue;
                }
            // `x / d` with d a compile-time constant: mulhu(x, M) >>u s. The
            // magic comes from the candidate, derived when the loop was
            // recognised. There is no fallback — a UDiv reaching here that the
            // recogniser did not clear would mean the loop should never have
            // been accepted, and the only "generic" lowering available is a
            // vector UDiv that no back end implements.
            if (op.equals(String.withCString("UDiv")))
                {
                Object* mo = c.divMagic() == (Map*)0
                                 ? (Object*)0
                                 : c.divMagic().get((Hashable*)n.res());
                if (mo == (Object*)0)
                    {
                    _vecBody.add((Object*)n);
                    continue;
                    }
                Array* mg = (Array*)mo;
                u32 mm = ((Number*)mg.get((u32)0)).asU32();
                u32 ss = ((Number*)mg.get((u32)1)).asU32();
                // (i64)mm, not (i32)mm. A magic multiplier has its top bit set
                // more often than not — 0xAAAAAAAB for /3 — and narrowing it to
                // i32 made the stored immediate NEGATIVE, so the IR printed
                // #-1431655765 where the reference prints #2863311531. Same
                // bits, different text, and the IR text is the contract.
                IROperand* vm = vecSplatOperand(IROperand.immI((i64)mm, n.res().ty()));
                IROperand* vx = vecSplatOperand((IROperand*)n.ops().get((u32)0));
                IRValue* hi = new IRValue(_vecTy);
                IRInsn* mh = IRInsn.with(String.withCString("VMulHi"));
                mh.copyDbg(n);
                mh.setRes(hi);
                mh.add(vx);
                mh.add(vm);
                _vecBody.add((Object*)mh);
                IRValue* qv = new IRValue(_vecTy);
                IRInsn* sr = IRInsn.with(String.withCString("VLShr"));
                sr.copyDbg(n);
                sr.setRes(qv);
                sr.add(IROperand.useVal(hi));
                sr.add(IROperand.immI((i32)ss, n.res().ty()));
                _vecBody.add((Object*)sr);
                _vecMap.set((Hashable*)n.res(), (Object*)qv);
                continue;
                }
            // Shift right by a constant: the lane-wise form takes the amount
            // as an immediate, not a splatted vector, so the second operand is
            // NOT run through vecSplatOperand. Splatting it would produce a
            // lane-wise variable shift that no back end here implements.
            if (op.equals(String.withCString("LShr")))
                {
                i32 sh = (i32)0;
                if (!vecConst((IROperand*)n.ops().get((u32)1), _vecSplatDefs, &sh))
                    {
                    _vecBody.add((Object*)n); // recogniser and applier disagree
                    continue;
                    }
                IROperand* vx = vecSplatOperand((IROperand*)n.ops().get((u32)0));
                IRValue* qv = new IRValue(_vecTy);
                IRInsn* sr = IRInsn.with(String.withCString("VLShr"));
                sr.copyDbg(n);
                sr.setRes(qv);
                sr.add(vx);
                sr.add(IROperand.immI(sh, c.laneTy()));
                _vecBody.add((Object*)sr);
                _vecMap.set((Hashable*)n.res(), (Object*)qv);
                continue;
                }
            // Shift left by a constant: as the shift right, the amount an
            // immediate.
            if (op.equals(String.withCString("Shl")))
                {
                i32 shl = (i32)0;
                if (!vecConst((IROperand*)n.ops().get((u32)1), _vecSplatDefs, &shl))
                    {
                    _vecBody.add((Object*)n); // recogniser and applier disagree
                    continue;
                    }
                IROperand* lx = vecSplatOperand((IROperand*)n.ops().get((u32)0));
                IRValue* lv = new IRValue(_vecTy);
                IRInsn* sl = IRInsn.with(String.withCString("VShl"));
                sl.copyDbg(n);
                sl.setRes(lv);
                sl.add(lx);
                sl.add(IROperand.immI(shl, c.laneTy()));
                _vecBody.add((Object*)sl);
                _vecMap.set((Hashable*)n.res(), (Object*)lv);
                continue;
                }
            // A bitwise not: one operand.
            if (op.equals(String.withCString("Not")))
                {
                IROperand* nx = vecSplatOperand((IROperand*)n.ops().get((u32)0));
                IRValue* nv = new IRValue(_vecTy);
                IRInsn* vn = IRInsn.with(String.withCString("VNot"));
                vn.copyDbg(n);
                vn.setRes(nv);
                vn.add(nx);
                _vecBody.add((Object*)vn);
                _vecMap.set((Hashable*)n.res(), (Object*)nv);
                continue;
                }
            // A lane square root (ONE operand) — the default below reads two.
            if (op.equals(String.withCString("FSqrt")))
                {
                IROperand* va = vecSplatOperand((IROperand*)n.ops().get((u32)0));
                IRValue* vr = new IRValue(_vecTy);
                IRInsn* vop = IRInsn.with(String.withCString("VSqrt"));
                vop.copyDbg(n);
                vop.setRes(vr);
                vop.add(va);
                _vecBody.add((Object*)vop);
                _vecMap.set((Hashable*)n.res(), (Object*)vr);
                continue;
                }
            IROperand* va = vecSplatOperand((IROperand*)n.ops().get((u32)0));
            IROperand* vb = vecSplatOperand((IROperand*)n.ops().get((u32)1));
            IRValue* vr = new IRValue(_vecTy);
            IRInsn* vop = IRInsn.with(self.vecOpFor(op));
            vop.copyDbg(n);
            vop.setRes(vr);
            vop.add(va);
            vop.add(vb);
            _vecBody.add((Object*)vop);
            _vecMap.set((Hashable*)n.res(), (Object*)vr);
            }
        B.setInsns(_vecBody);
        }

    final IROperand* vecSplatOperand(IROperand* op)
        {
        if (_vecSplatPH != (IRBlock*)0 && op.kind() == (u8)OPK_IMMI)
            return self.vecSplatConst(op.imm());
        if (op.kind() == (u8)OPK_USE)
            {
            Object* vv = _vecMap.get((Hashable*)op.val());
            if (vv != (Object*)0)
                return IROperand.useVal((IRValue*)vv);
            if (_vecSplatPH != (IRBlock*)0)
                {
                i32 kv = (i32)0;
                if (vecConst(op, _vecSplatDefs, &kv))
                    return self.vecSplatConst(kv);
                }
            // In a large body each use has its own splat: one kept for the
            // next use would be live across the rounds between.
            Object* sp = _vecSplatBig ? (Object*)0 : _vecSplat.get((Hashable*)op.val());
            if (sp == (Object*)0)
                {
                IRValue* v = new IRValue(_vecTy);
                IRInsn* s = IRInsn.with(String.withCString("VSplat"));
                s.setRes(v);
                s.add(op);
                _vecBody.add((Object*)s);
                if (!_vecSplatBig)
                    _vecSplat.set((Hashable*)op.val(), (Object*)v);
                sp = (Object*)v;
                }
            return IROperand.useVal((IRValue*)sp);
            }
        IRValue* v = new IRValue(_vecTy);
        IRInsn* s = IRInsn.with(String.withCString("VSplat"));
        s.setRes(v);
        s.add(op);
        _vecBody.add((Object*)s);
        return IROperand.useVal(v);
        }

    // The vector form of a scalar body operand: an already-vectorised value, an
    // entry-hoisted broadcast of a loop-invariant scalar, or a per-body VSplat.
    final IROperand* vecOperandFor(IROperand* op, IRFunc* fn, IRBlock* entry, IRBlock* B,
                             VecCand* c, Map* defOf, Map* defBlk)
        {
        if (op.kind() == (u8)OPK_USE)
            {
            Object* vv = _vecMap.get((Hashable*)op.val());
            if (vv != (Object*)0)
                return IROperand.useVal((IRValue*)vv);
            }
        IROperand* hoisted = vecEntrySplat(op, fn, entry, B, c, defOf, defBlk);
        if (hoisted != (IROperand*)0)
            return hoisted;
        if (op.kind() == (u8)OPK_USE)
            {
            // In a large body each use has its own splat: one kept for the
            // next use would be live across the rounds between.
            Object* sp = _vecSplatBig ? (Object*)0 : _vecSplat.get((Hashable*)op.val());
            if (sp == (Object*)0)
                {
                IRValue* v = new IRValue(_vecTy);
                IRInsn* s = IRInsn.with(String.withCString("VSplat"));
                s.setRes(v);
                s.add(op);
                _vecBody.add((Object*)s);
                if (!_vecSplatBig)
                    _vecSplat.set((Hashable*)op.val(), (Object*)v);
                sp = (Object*)v;
                }
            return IROperand.useVal((IRValue*)sp);
            }
        // An immediate: broadcast straight from it.
        IRValue* v = new IRValue(_vecTy);
        IRInsn* s = IRInsn.with(String.withCString("VSplat"));
        s.setRes(v);
        s.add(op);
        _vecBody.add((Object*)s);
        return IROperand.useVal(v);
        }

    // Hoist a LOOP-INVARIANT operand's broadcast to the function ENTRY block.
    // Entry dominates every loop, including any enclosing one, so the splat is
    // materialised once on the way in rather than every iteration — and it stays
    // correct under nesting, which hoisting to a particular preheader does not.
    // Null when the operand is not provably entry-dominating; the caller then
    // keeps the in-body splat.
    final IROperand* vecEntrySplat(IROperand* op, IRFunc* fn, IRBlock* entry, IRBlock* B,
                             VecCand* c, Map* defOf, Map* defBlk)
        {
        if (entry == (IRBlock*)0 || entry == B || entry == c.h())
            return (IROperand*)0;
        i32 kv = (i32)0;
        bool isConst = vecConst(op, defOf, &kv);
        String* ck = (String*)0;
        if (isConst)
            {
            ck = new String();
            ck.appendFormat("c%ld", kv);
            }
        else if (op.kind() == (u8)OPK_USE)
            {
            ck = self.vecValueKey(fn, op.val());
            }
        if (ck != (String*)0)
            {
            Object* hit = _vecEntryCache.get((Hashable*)ck);
            if (hit != (Object*)0)
                return IROperand.useVal((IRValue*)hit);
            }
        IROperand* scalar = (IROperand*)0;
        if (isConst)
            {
            IRValue* cst = new IRValue(c.laneTy());
            IRInsn* ci = IRInsn.with(String.withCString("Const"));
            ci.setRes(cst);
            ci.add(IROperand.immI(kv, c.laneTy()));
            entry.insns().add((Object*)ci);
            scalar = IROperand.useVal(cst);
            }
        else if (op.kind() == (u8)OPK_USE)
            {
            // A parameter has no defining instruction and is available at
            // entry; an entry-defined value dominates the rest of entry.
            // Anything defined mid-CFG cannot be named from entry. A nil
            // defBlk proves NOTHING beyond "absent when the map was built":
            // a value CREATED by vectorising an earlier loop (the new outer
            // phi carrying an induction var) is missing from the stale map,
            // and treating absent-as-param hoisted its splat to entry, where
            // it read default 0. Only a REAL param may hoist on nil.
            Object* db = defBlk.get((Hashable*)op.val());
            if (db != (Object*)0 && (IRBlock*)db != entry)
                return (IROperand*)0;
            if (db == (Object*)0)
                {
                bool isParam = false;
                for (u32 pi = (u32)0; pi < fn.params().count(); pi = pi + (u32)1)
                    if ((IRValue*)fn.params().get(pi) == op.val())
                        {
                        isParam = true;
                        break;
                        }
                if (!isParam)
                    return (IROperand*)0;
                }
            scalar = op;
            }
        else
            {
            return (IROperand*)0;
            }
        IRValue* sp = new IRValue(_vecTy);
        IRInsn* s = IRInsn.with(String.withCString("VSplat"));
        s.setRes(sp);
        s.add(scalar);
        entry.insns().add((Object*)s);
        if (ck != (String*)0)
            _vecEntryCache.set((Hashable*)ck, (Object*)sp);
        return IROperand.useVal(sp);
        }
    }
